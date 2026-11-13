-- Research only (the TV mode's thread): picks WANTED in the Simulator's
-- External Displays menu ("1920" for a 1080p display, "Disabled" for none),
-- wherever the menu is. Removed before the pull request.
on run argv
	set wanted to item 1 of argv
	tell application "Simulator" to activate
	delay 1
	set AppleScript's text item delimiters to " | "
	tell application "System Events"
		tell process "Simulator"
			set frontmost to true
			set found to false
			set seen to {}
			repeat with barItem in menu bar items of menu bar 1
				try
					set barName to name of barItem
					repeat with anItem in menu items of menu 1 of barItem
						try
							set itemName to name of anItem
							if itemName is not missing value and itemName contains "External Display" then
								set choices to menu items of menu 1 of anItem
								set names to {}
								repeat with choice in choices
									try
										set end of names to (name of choice as text)
									end try
								end repeat
								log "menu " & barName & " > " & itemName & ": " & (names as text)
								repeat with choice in choices
									try
										if (name of choice as text) contains wanted then
											click choice
											set found to true
											log "clicked " & (name of choice as text)
											exit repeat
										end if
									end try
								end repeat
							end if
						end try
						if found then exit repeat
					end repeat
				end try
				if found then exit repeat
			end repeat
			if not found then
				repeat with barItem in menu bar items of menu bar 1
					try
						set end of seen to (name of barItem as text) & ": " & ((name of every menu item of menu 1 of barItem) as text)
					end try
				end repeat
				error "no External Displays item with " & wanted & ". Menus: " & (seen as text)
			end if
		end tell
	end tell
end run
