-- Media control for whichever player is running: Spotify first, then Music.
-- usage: osascript media.applescript playpause|play|pause|next|previous
on run argv
	set cmd to item 1 of argv
	if application "Spotify" is running then
		tell application "Spotify"
			if cmd is "playpause" then playpause
			if cmd is "play" then play
			if cmd is "pause" then pause
			if cmd is "next" then next track
			if cmd is "previous" then previous track
		end tell
	else if application "Music" is running then
		tell application "Music"
			if cmd is "playpause" then playpause
			if cmd is "play" then play
			if cmd is "pause" then pause
			if cmd is "next" then next track
			if cmd is "previous" then previous track
		end tell
	end if
end run
