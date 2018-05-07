--[[
 $Id$

 Copyright © 2007-2017 the VideoLAN team

 This program is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.

 This program is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.

 You should have received a copy of the GNU General Public License
 along with this program; if not, write to the Free Software
 Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
--]]

-- Helper function to get a parameter's value in a URL
function get_url_param( url, name )
    local _, _, res = string.find( url, "[&?]"..name.."=([^&]*)" )
    return res
end

-- Helper function to copy a parameter when building a new URL
function copy_url_param( url, name )
    local value = get_url_param( url, name )
    return ( value and "&"..name.."="..value or "" ) -- Ternary operator
end

function get_arturl()
    local iurl = get_url_param( vlc.path, "iurl" )
    if iurl then
        return iurl
    end
    local video_id = get_url_param( vlc.path, "v" )
    if not video_id then
        return nil
    end
    return vlc.access.."://img.youtube.com/vi/"..video_id.."/default.jpg"
end

-- Pick the most suited format available
function get_fmt( fmt_list )
    local prefres = vlc.var.inherit(nil, "preferred-resolution")
    if prefres < 0 then
        return nil
    end

    local fmt = nil
    for itag,height in string.gmatch( fmt_list, "(%d+)/%d+x(%d+)[^,]*" ) do
        -- Apparently formats are listed in quality
        -- order, so we take the first one that works,
        -- or fallback to the lowest quality
        fmt = itag
        if tonumber(height) <= prefres then
            break
        end
    end
    return fmt
end

-- Buffering iterator to parse through the HTTP stream several times
-- without making several HTTP requests
function buf_iter( s )
    s.i = s.i + 1
    local line = s.lines[s.i]
    if not line then
        -- Put back together statements split across several lines,
        -- otherwise we won't be able to parse them
        repeat
            local l = s.stream:readline()
            if not l then break end
            line = line and line..l or l -- Ternary operator
        until string.match( line, "};$" )

        if line then
            s.lines[s.i] = line
        end
    end
    return line
end

-- Helper to search and extract code from javascript stream
function js_extract( js, pattern )
    js.i = 0 -- Reset to beginning
    for line in buf_iter, js do
        local ex = string.match( line, pattern )
        if ex then
            return ex
        end
    end
    vlc.msg.err( "Couldn't process youtube video URL, please check for updates to this script" )
    return nil
end

-- Descramble the URL signature using the javascript code that does that
-- in the web page
function js_descramble( sig, js_url )
    -- Fetch javascript code
    local js = { stream = vlc.stream( js_url ), lines = {}, i = 0 }
    if not js.stream then
        vlc.msg.err( "Couldn't process youtube video URL, please check for updates to this script" )
        return sig
    end

    -- Look for the descrambler function's name
    -- k.s&&f.set(k.sp||"signature",DK(k.s));
    local descrambler = js_extract( js, "%.set%([^,]-\"signature\",([^)]-)%(" )
    if not descrambler then
        vlc.msg.dbg( "Couldn't extract youtube video URL signature descrambling function name" )
        return sig
    end

    -- Fetch the code of the descrambler function
    -- Go=function(a){a=a.split("");Fo.sH(a,2);Fo.TU(a,28);Fo.TU(a,44);Fo.TU(a,26);Fo.TU(a,40);Fo.TU(a,64);Fo.TR(a,26);Fo.sH(a,1);return a.join("")};
    local rules = js_extract( js, "^"..descrambler.."=function%([^)]*%){(.-)};" )
    if not rules then
        vlc.msg.dbg( "Couldn't extract youtube video URL signature descrambling rules" )
        return sig
    end

    -- Get the name of the helper object providing transformation definitions
    local helper = string.match( rules, ";(..)%...%(" )
    if not helper then
        vlc.msg.dbg( "Couldn't extract youtube video URL signature transformation helper name" )
        vlc.msg.err( "Couldn't process youtube video URL, please check for updates to this script" )
        return sig
    end

    -- Fetch the helper object code
    -- var Fo={TR:function(a){a.reverse()},TU:function(a,b){var c=a[0];a[0]=a[b%a.length];a[b]=c},sH:function(a,b){a.splice(0,b)}};
    local transformations = js_extract( js, "[ ,]"..helper.."={(.-)};" )
    if not transformations then
        vlc.msg.dbg( "Couldn't extract youtube video URL signature transformation code" )
        return sig
    end

    -- Parse the helper object to map available transformations
    local trans = {}
    for meth,code in string.gmatch( transformations, "(..):function%([^)]*%){([^}]*)}" ) do
        -- a=a.reverse()
        if string.match( code, "%.reverse%(" ) then
          trans[meth] = "reverse"

        -- a.splice(0,b)
        elseif string.match( code, "%.splice%(") then
          trans[meth] = "slice"

        -- var c=a[0];a[0]=a[b%a.length];a[b]=c
        elseif string.match( code, "var c=" ) then
          trans[meth] = "swap"
        else
            vlc.msg.warn("Couldn't parse unknown youtube video URL signature transformation")
        end
    end

    -- Parse descrambling rules, map them to known transformations
    -- and apply them on the signature
    local missing = false
    for meth,idx in string.gmatch( rules, "..%.(..)%([^,]+,(%d+)%)" ) do
        idx = tonumber( idx )

        if trans[meth] == "reverse" then
            sig = string.reverse( sig )

        elseif trans[meth] == "slice" then
            sig = string.sub( sig, idx + 1 )

        elseif trans[meth] == "swap" then
            if idx > 1 then
                sig = string.gsub( sig, "^(.)("..string.rep( ".", idx - 1 )..")(.)(.*)$", "%3%2%1%4" )
            elseif idx == 1 then
                sig = string.gsub( sig, "^(.)(.)", "%2%1" )
            end
        else
            vlc.msg.dbg("Couldn't apply unknown youtube video URL signature transformation")
            missing = true
        end
    end
    if missing then
        vlc.msg.err( "Couldn't process youtube video URL, please check for updates to this script" )
    end
    return sig
end

-- Parse and pick our video URL
function pick_url( url_map, fmt, js_url )
    local path = nil
    for stream in string.gmatch( url_map, "[^,]+" ) do
        -- Apparently formats are listed in quality order,
        -- so we can afford to simply take the first one
        local itag = string.match( stream, "itag=(%d+)" )
        if not fmt or not itag or tonumber( itag ) == tonumber( fmt ) then
            local url = string.match( stream, "url=([^&,]+)" )
            if url then
                url = vlc.strings.decode_uri( url )

                local sig = string.match( stream, "sig=([^&,]+)" )
                if not sig then
                    -- Scrambled signature
                    sig = string.match( stream, "s=([^&,]+)" )
                    if sig then
                        vlc.msg.dbg( "Found "..string.len( sig ).."-character scrambled signature for youtube video URL, attempting to descramble... " )
                        if js_url then
                            sig = js_descramble( sig, js_url )
                        else
                            vlc.msg.err( "Couldn't process youtube video URL, please check for updates to this script" )
                        end
                    end
                end
                local signature = ""
                if sig then
                    signature = "&signature="..sig
                end

                path = url..signature
                break
            end
        end
    end
    return path
end

-- Probe function.
function probe()
    return ( ( vlc.access == "http" or vlc.access == "https" )
             and string.match( vlc.path, "^www%.youtube%.com/" )
             and (
               string.match( vlc.path, "/watch%?" ) -- the html page
            or string.match( vlc.path, "/live$" ) -- user live stream html page
            or string.match( vlc.path, "/live%?" ) -- user live stream html page
            or string.match( vlc.path, "/get_video_info%?" ) -- info API
            or string.match( vlc.path, "/v/" ) -- video in swf player
            or string.match( vlc.path, "/embed/" ) -- embedded player iframe
						-- My Hack Begin[20170110]: add youtube playlist processing (path, name, thumbnail)
            or string.match( vlc.path, "/playlist%?" ) -- playlist
						-- My Hack End[20170110]: add youtube playlist processing (path, name, thumbnail)
             ) )
end
-- My Hack Begin[20170110]: autonextplay, the endless playing with the next video
function parse_json(str)
  vlc.msg.dbg("Parsing JSON: " .. str)
  local json = require("dkjson")
  return json.decode(str)
end
-- My Hack End[20170110]: autonextplay, the endless playing with the next video

-- My Hack Begin[20170110]: unescape
-- http://lua.org/pil/20.3.html
--function unescape (s)
--	s = string.gsub(s, "+", " ")
--	s = string.gsub(s, "%%(%x%x)", function (h) return string.char(tonumber(h, 16)) end)
--	return s
--end

-- http://stackoverflow.com/questions/14899734/unescape-numeric-xml-entities-with-lua
local hex_to_char = function(x)
  return string.char(tonumber(x, 16))
end

local hex_to_char = function(x)
  return string.char(tonumber(x, 16))
end

local unescape = function(s)
  s = string.gsub(s, '&lt;', '<')
  s = string.gsub(s, '&gt;', '>')
  s = string.gsub(s, '&quot;', '"')
  s = string.gsub(s, '&apos;', "'")
	s = string.gsub(s, "+", " ")
	s = string.gsub(s, '&#(%d+);', function(n) return string.char(n) end)
--	s = string.gsub(s, '&#x(%d+);', hex_to_char)
  s = s:gsub("%%(%x%x)", hex_to_char)
	s = string.gsub(s, '&amp;', '&' ) -- be sure to do this after all others
	return s
end
-- My Hack End[20170110]: unescape

-- Parse function.
function parse()
		-- My Hack Begin[20170110]: add youtube playlist processing (path, name, thumbnail)
		-- eg http://youtube.com/playlist?list=PL6dFtv5p3AFdo7Rf9wc30suXID3L5du8W
		--TODO YouT give first only max 100 items, so maybe process others with next request...
		if string.match( vlc.path, "/playlist%?" )
		then
			-- http://addons.videolan.org/p/1154080/
			-- example http://gist.github.com/stefansundin/c200324149bb00001fef5a252a120fc2
			--vlc.msg.err( "Under Construction" )
			local line = nil
			local path = nil
			local name = nil
			local thumbnail = nil
			local tmp = nil
			local items = {}
			local item = nil
			while true do
				line = vlc.readline()
				if not line then break end
				--if line == nil then break end

				-- http://lua-users.org/wiki/PatternsTutorial
				-- http://www.lua.org/manual/5.3/manual.html#6.4.1
				--if string.find(line, "data[-]video[-]id=") then
				--path = string.match(line, "data[-]video[-]id=\"([^\"]+)\"")
				vlc.msg.dbg( "[cucc] " .. line)
				path = string.match(line, "data%-video%-id=\"(.-)\"")
				if path then
					--path = unescape(path)
					name = unescape(string.match(line, "data%-title=\"(.-)\""))
					item = { path = "https://www.youtube.com/watch?v=" .. path, name = name }
					vlc.msg.dbg("YouTube Playlist item found: " .. item.path .. " (" .. item.name .. ")")
					table.insert(items, item)
				else
					-- these items are in next line
					if item then
						thumbnail = string.match(line, "data%-thumb=\"(.-)\"")
						if thumbnail then
							item["arturl"] = thumbnail
							vlc.msg.warn("  add thumbnail: " .. thumbnail)
						--[[else
							--TODO the next items...
							tmp = string.match(line, "data%-uix%-load%-more%-href=\"(.-)\"")
							if tmp then
								vlc.msg.dbg("YouTube Next Playlist item found: " .. tmp)
								table.insert(items, { path = "https://www.youtube.com" .. tmp })
							end
						--]]
						end
					end
				end
			end
			return items

		--if string.match( vlc.path, "/watch%?" )
    elseif string.match( vlc.path, "/watch%?" )
		-- My Hack End[20170110]: add youtube playlist processing (path, name, thumbnail)
        or string.match( vlc.path, "/live$" )
        or string.match( vlc.path, "/live%?" )
    then -- This is the HTML page's URL
        -- fmt is the format of the video
        -- (cf. http://en.wikipedia.org/wiki/YouTube#Quality_and_formats)
        fmt = get_url_param( vlc.path, "fmt" )
				-- My Hack Begin[20170110]: autonextplay, the endless playing with the next video
				-- eg http://youtu.be/KKLT_0qavoU?autonextplay
				-- eg https://www.youtube.com/watch?v=KKLT_0qavoU&autonextplay
				local autonextplay = string.match(vlc.path, "&autonextplay")
				local nextplay = nil
				-- My Hack End[20170110]: autonextplay, the endless playing with the next video
        while true do
            -- Try to find the video's title
            line = vlc.readline()
            if not line then break end
            if string.match( line, "<meta property=\"og:title\"" ) then
                _,_,name = string.find( line, "content=\"(.-)\"" )
                name = vlc.strings.resolve_xml_special_chars( name )
                name = vlc.strings.resolve_xml_special_chars( name )
            end

						-- My Hack Begin[20170110]: autonextplay, the endless playing with the next video
						if autonextplay then
							-- get the next first...
							-- YouT don't give JSON to VLC?
							--nextplay = string.match(line, "window%[\"ytInitialData\"%]%s*=%s*(.*);%s*$")
							nextplay = string.match(line, "data%-vid=\"(.-)\"")
							if nextplay then
								--vlc.msg.dbg("JSON: " .. nextplay)
								autonextplay = false
							end
						end
						-- My Hack End[20170110]: autonextplay, the endless playing with the next video

            if not description then
                description = string.match( line, "<p id=\"eow%-description\"[^>]*>(.-)</p>" )
                if description then
                    description = vlc.strings.resolve_xml_special_chars( description )
                end
            end

            if string.match( line, "<meta property=\"og:image\"" ) then
                _,_,arturl = string.find( line, "content=\"(.-)\"" )
                arturl = vlc.strings.resolve_xml_special_chars( arturl )
            end

            if string.match(line, "\"author\": *\"(.-)\"")    then
                _,_,artist = string.find(line, "\"author\": *\"(.-)\"")
            end

            -- JSON parameters, also formerly known as "swfConfig",
            -- "SWF_ARGS", "swfArgs", "PLAYER_CONFIG", "playerConfig" ...
            if string.match( line, "ytplayer%.config" ) then

                local js_url = string.match( line, "\"js\": *\"(.-)\"" )
                if js_url then
                    js_url = string.gsub( js_url, "\\/", "/" )
                    -- Resolve URL
                    if string.match( js_url, "^/[^/]" ) then
                        local authority = string.match( vlc.path, "^([^/]*)/" )
                        js_url = "//"..authority..js_url
                    end
                    js_url = string.gsub( js_url, "^//", vlc.access.."://" )
                end

                if not fmt then
                    fmt_list = string.match( line, "\"fmt_list\": *\"(.-)\"" )
                    if fmt_list then
                        fmt_list = string.gsub( fmt_list, "\\/", "/" )
                        fmt = get_fmt( fmt_list )
                    end
                end

                url_map = string.match( line, "\"url_encoded_fmt_stream_map\": *\"(.-)\"" )
                if url_map then
                    -- FIXME: do this properly
                    url_map = string.gsub( url_map, "\\u0026", "&" )
                    path = pick_url( url_map, fmt, js_url )
                end

                if not path then
                    -- If this is a live stream, the URL map will be empty
                    -- and we get the URL from this field instead
                    local hlsvp = string.match( line, "\"hlsvp\": *\"(.-)\"" )
                    if hlsvp then
                        hlsvp = string.gsub( hlsvp, "\\/", "/" )
                        path = hlsvp
                    end
                end
            -- There is also another version of the parameters, encoded
            -- differently, as an HTML attribute of an <object> or <embed>
            -- tag; but we don't need it now
            end
        end

        if not path then
            local video_id = get_url_param( vlc.path, "v" )
            if video_id then
                -- Passing no "el" parameter to /get_video_info seems to
                -- let it default to "embedded", and both known values
                -- of "embedded" and "detailpage" are wrong and fail for
                -- various restricted videos, so we pass a different value
                path = vlc.access.."://www.youtube.com/get_video_info?video_id="..video_id.."&el=detail"..copy_url_param( vlc.path, "fmt" )
                vlc.msg.warn( "Couldn't extract video URL, falling back to alternate youtube API" )
            end
        end

        if not path then
            vlc.msg.err( "Couldn't extract youtube video URL, please check for updates to this script" )
            return { }
        end

        if not arturl then
            arturl = get_arturl()
        end

        -- My Hack Begin[20170110]: autonextplay, the endless playing with the next video
				--return { { path = path; name = name; description = description; artist = artist; arturl = arturl } }
				local items = { { path = path; name = name; description = description; artist = artist; arturl = arturl } }
				if nextplay then
					-- add the next video with autonextplay, so neverending story :)
					table.insert(items, { path = "https://www.youtube.com/watch?v=" .. nextplay .. "&autonextplay" })
				end
				return items
				-- My Hack End[20170110]: autonextplay, the endless playing with the next video

    elseif string.match( vlc.path, "/get_video_info%?" ) then -- video info API
        local line = vlc.readline() -- data is on one line only

        local fmt = get_url_param( vlc.path, "fmt" )
        if not fmt then
            local fmt_list = string.match( line, "&fmt_list=([^&]*)" )
            if fmt_list then
                fmt_list = vlc.strings.decode_uri( fmt_list )
                fmt = get_fmt( fmt_list )
            end
        end

        local url_map = string.match( line, "&url_encoded_fmt_stream_map=([^&]*)" )
        if url_map then
            url_map = vlc.strings.decode_uri( url_map )
            path = pick_url( url_map, fmt )
        end

        if not path then
            -- If this is a live stream, the URL map will be empty
            -- and we get the URL from this field instead
            local hlsvp = string.match( line, "&hlsvp=([^&]*)" )
            if hlsvp then
                hlsvp = vlc.strings.decode_uri( hlsvp )
                path = hlsvp
            end
        end

        if not path then
            vlc.msg.err( "Couldn't extract youtube video URL, please check for updates to this script" )
            return { }
        end

        local title = string.match( line, "&title=([^&]*)" )
        if title then
            title = string.gsub( title, "+", " " )
            title = vlc.strings.decode_uri( title )
        end
        local artist = string.match( line, "&author=([^&]*)" )
        if artist then
            artist = string.gsub( artist, "+", " " )
            artist = vlc.strings.decode_uri( artist )
        end
        local arturl = string.match( line, "&thumbnail_url=([^&]*)" )
        if arturl then
            arturl = vlc.strings.decode_uri( arturl )
        end

        return { { path = path, title = title, artist = artist, arturl = arturl } }

    else -- Other supported URL formats
        local video_id = string.match( vlc.path, "/[^/]+/([^?]*)" )
        if not video_id then
            vlc.msg.err( "Couldn't extract youtube video URL" )
            return { }
        end
        return { { path = vlc.access.."://www.youtube.com/watch?v="..video_id..copy_url_param( vlc.path, "fmt" ) } }
    end
end
