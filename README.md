# vlc_youtubeplaylist
Use/play the VLC Player for YouTube playlists!

You can use the VLC Player for YouTube videos playing with default youtube.lua plugin, this further version of plugin allows play the playlists.
  eg http://youtube.com/playlist?list=PL6dFtv5p3AFdo7Rf9wc30suXID3L5du8W
Restriction: the YouTube download only links of 100 videos first, so this plugin load only this first 100! (further development: it to handle this.)

~ more feature: you can use the autonextplay parameter in the video link for Play Next Video Automatically function (as neverending story! :)
  eg http://youtu.be/KKLT_0qavoU?autonextplay
  eg https://www.youtube.com/watch?v=KKLT_0qavoU&autonextplay

Install: copy the youtube.lua file in the vlc /lua/playlist folder, by default:
+ Windows (all users): %ProgramFiles%\VideoLAN\VLC\lua\playlist\
+ Windows (current user only): %APPDATA%\vlc\lua\playlist\
+ Linux (all users): /usr/lib/vlc/lua/playlist/
+ Linux (current user only): ~/.local/share/vlc/lua/playlist/
+ Mac OS X (all users): /Applications/VLC.app/Contents/MacOS/share/lua/playlist/
And enjoy the silence!
(Tested with current latest 2.2.6 VLC release on Win 7 x64 and Windows XP x86.)
