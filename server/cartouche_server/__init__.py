"""Tools that publish Cartouche's update channel: the signed manifest and its chunks."""

# The bundle identifier Cartouche is built with (app/config.env). The publish
# guard refuses an IPA with any other identifier.
APP_BUNDLE_ID = "io.github.clabeuhtegrite.cartouche"

__all__ = ["APP_BUNDLE_ID"]
