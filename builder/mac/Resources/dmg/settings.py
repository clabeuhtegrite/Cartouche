# dmgbuild's settings for Cartouche Builder's disk image (make_dmg.sh): the
# app and a link to Applications side by side on the background, where the
# arrow between them says to drag one onto the other. dmgbuild runs this file
# with the defines make_dmg.sh passes: app, background and icon.
#
# The window's bounds include its title bar, about 28 points: the background
# is 448 points high for its content to be 420 to 448 high, and nothing it
# says sits in its last 36 points. The row of the icons' names, from 266 to
# 292, is one colour of relative luminance 0.18, on which the Finder's black
# names (light) and white ones (dark) both read at 4.5:1 (background.html).

import os.path

application = defines["app"]  # noqa: F821, dmgbuild's
app_name = os.path.basename(application)

format = "ULFO"
files = [application]
symlinks = {"Applications": "/Applications"}
icon = defines.get("icon")  # noqa: F821
background = defines["background"]  # noqa: F821

window_rect = ((200, 120), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 128
text_size = 13
label_pos = "bottom"
arrange_by = None
icon_locations = {
    app_name: (170, 196),
    "Applications": (490, 196),
}
