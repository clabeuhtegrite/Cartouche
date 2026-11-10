import unittest
from pathlib import Path

from cartouche_builder import shares

MOUNT = """/dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
//player@nas.local/Games on /Volumes/Games (smbfs, nodev, nosuid, mounted by player)
//nas.local/Other%20Share on /Volumes/Other Share (smbfs, nodev, nosuid, mounted by player)
map auto_home on /System/Volumes/Data/home (autofs, automounted, nobrowse)
"""


class Shares(unittest.TestCase):
    def test_mounted_shares(self):
        self.assertEqual(shares.mounts(MOUNT), {
            "/Volumes/Games": "smb://player@nas.local/Games",
            "/Volumes/Other Share": "smb://nas.local/Other%20Share",
        })

    def test_the_share_of_a_folder(self):
        mounted = shares.mounts(MOUNT)
        self.assertEqual(shares.share_of(Path("/Volumes/Games/Sources"), mounted), ("/Volumes/Games", "smb://player@nas.local/Games"))
        self.assertIsNone(shares.share_of(Path("/Volumes/GamesOther/x"), mounted))
        self.assertIsNone(shares.share_of(Path("/Users/player/Games"), mounted))

    def test_remember(self):
        known = shares.remember([Path("/Volumes/Games/Jeux"), Path("/Users/player/x")], {"/Volumes/Old": "smb://old/Old"}, shares.mounts(MOUNT))
        self.assertEqual(known, {"/Volumes/Old": "smb://old/Old", "/Volumes/Games": "smb://player@nas.local/Games"})


if __name__ == "__main__":
    unittest.main()
