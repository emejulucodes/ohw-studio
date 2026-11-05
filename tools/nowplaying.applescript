-- Prints: player|state|title|artist|position_seconds|volume_0_100   (empty line if nothing plays)
on run
	set sep to "|"
	if application "Spotify" is running then
		tell application "Spotify"
			try
				set pState to (player state as string)
				set tName to name of current track
				set tArtist to artist of current track
				set tPos to player position
				set tVol to sound volume
				return "Spotify" & sep & pState & sep & tName & sep & tArtist & sep & (tPos as integer) & sep & tVol
			end try
		end tell
	end if
	if application "Music" is running then
		tell application "Music"
			try
				set pState to (player state as string)
				set tName to name of current track
				set tArtist to artist of current track
				set tPos to player position
				set tVol to sound volume
				return "Music" & sep & pState & sep & tName & sep & tArtist & sep & (tPos as integer) & sep & tVol
			end try
		end tell
	end if
	return ""
end run
