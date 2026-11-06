"""The publish guard: refuses anything that looks like game content before it is published."""

# The bundle identifier Cartouche is built with (app/config.env). The publish
# guard refuses an IPA with any other identifier.
APP_BUNDLE_ID = "io.github.clabeuhtegrite.cartouche"

__all__ = ["APP_BUNDLE_ID"]
