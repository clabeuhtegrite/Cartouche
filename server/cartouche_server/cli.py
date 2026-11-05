"""cartouche-server: publish Cartouche's update channel.

    cartouche-server keygen --out manifest.key
    cartouche-server check --kind engine-host build/host.dylib
    cartouche-server publish release.json --store out/ --key-env CARTOUCHE_MANIFEST_KEY
    cartouche-server verify --store out/ --channel stable --public-key server/keys/stable.pub

``publish`` and ``verify`` work on a local folder laid out like the bucket;
CI syncs that folder to Cloudflare R2 afterwards.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

from . import APP_BUNDLE_ID, guard, signing, store


def _private_key(args: argparse.Namespace) -> str:
    if args.key_env:
        value = os.environ.get(args.key_env)
        if not value:
            raise SystemExit(f"the environment variable {args.key_env} is not set")
        return value
    if args.key_file:
        return Path(args.key_file).read_text()
    raise SystemExit("give the signing key with --key-env or --key-file")


def cmd_keygen(args: argparse.Namespace) -> int:
    out = Path(args.out)
    if out.exists():
        raise SystemExit(f"{out} exists; refusing to overwrite a signing key")
    private, public = signing.generate()
    fd = os.open(out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as handle:
        handle.write(private + "\n")
    print(f"private key written to {out} (keep it secret: store it as a CI secret, never commit it)")
    print(f"public key: {public}")
    return 0


def cmd_check(args: argparse.Namespace) -> int:
    failed = False
    for name in args.files:
        try:
            guard.check_file(Path(name), args.kind, app_bundle_id_expected=args.app_bundle_id)
        except guard.Rejected as exc:
            print(f"REFUSED {exc}", file=sys.stderr)
            failed = True
        else:
            print(f"ok      {name}")
    return 1 if failed else 0


def cmd_publish(args: argparse.Namespace) -> int:
    channel, items = store.read_spec(Path(args.spec))
    try:
        manifest = store.publish(
            Path(args.store),
            channel,
            items,
            private_key=_private_key(args),
            app_bundle_id=args.app_bundle_id,
        )
    except (guard.Rejected, store.StoreError) as exc:
        print(f"REFUSED {exc}", file=sys.stderr)
        return 1
    print(f"{channel}: sequence {manifest.sequence}, {len(manifest.artifacts)} artifacts")
    for artifact in sorted(manifest.artifacts, key=lambda a: a.id):
        print(f"  {artifact.id} {artifact.version} ({artifact.size} bytes, {len(artifact.chunks)} chunks)")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    public_key = Path(args.public_key).read_text().strip()
    problems = store.verify(Path(args.store), args.channel, public_key)
    for problem in problems:
        print(problem, file=sys.stderr)
    if not problems:
        print(f"{args.channel}: signature and chunks are sound")
    return 1 if problems else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="cartouche-server", description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    keygen = sub.add_parser("keygen", help="create a manifest signing key")
    keygen.add_argument("--out", required=True, help="file to write the private key to")
    keygen.set_defaults(func=cmd_keygen)

    check = sub.add_parser("check", help="run the publish guard on files")
    check.add_argument("--kind", required=True, choices=sorted(guard.MAX_SIZE))
    check.add_argument("--app-bundle-id", default=APP_BUNDLE_ID)
    check.add_argument("files", nargs="+")
    check.set_defaults(func=cmd_check)

    publish = sub.add_parser("publish", help="guard, chunk and sign a release into a store folder")
    publish.add_argument("spec", help="release spec (JSON)")
    publish.add_argument("--store", required=True, help="local folder laid out like the bucket")
    publish.add_argument("--key-env", help="environment variable holding the private key")
    publish.add_argument("--key-file", help="file holding the private key")
    publish.add_argument("--app-bundle-id", default=APP_BUNDLE_ID)
    publish.set_defaults(func=cmd_publish)

    verify = sub.add_parser("verify", help="check a channel's signature and chunks")
    verify.add_argument("--store", required=True)
    verify.add_argument("--channel", required=True)
    verify.add_argument("--public-key", required=True, help="file holding the public key")
    verify.set_defaults(func=cmd_verify)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
