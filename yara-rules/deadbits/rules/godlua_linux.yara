rule GodLua_Linux: linuxmalware
{
   meta:
      Author = "Adam M. Swanda"
      Website = "https://www.deadbits.org"
      Repo = "https://github.com/deadbits/yara-rules"
      Date = "2019-07-18"

   strings:

      $tmp0 = "/tmp" ascii fullword
      $tmp1 = "TMPDIR" ascii

      $str1 = "\"description\": \"" ascii fullword
      $str2 = "searchers" ascii fullword
      $str3 = "/dev/misc/watchdog" ascii fullword
      $str4 = "/dev/wdt" ascii fullword
      $str5 = "/dev/misc/wdt"
      $str6 = "lcurl.safe" ascii fullword
      $str7 = "luachild" ascii fullword
      $str8 = "cjson.safe" ascii fullword
      $str9 = "HostUrl" ascii fullword
      $str10 = "HostConnect" ascii fullword
      $str11 = "LUABOX" ascii fullword
      $str12 = "Infinity" ascii fullword
      $str13 = "/bin/sh" ascii fullword
      $str14 = /\.onion(\.)?/ ascii fullword
      $str15 = "/etc/resolv.conf" ascii fullword
      $str16 = "hosts:" ascii fullword

      $resolvers = /([0-9]{1,3}\.){3}[0-9]{1,3}:53,([0-9]{1,3}\.){3}[0-9]{1,3},([0-9]{1,3}\.){3}[0-9]{1,3}:5353,([0-9]{1,3}\.){3}[0-9]{1,3}:443/ ascii

      $identifier0 = "$LuaVersion: God " ascii
      $identifier1 = /fbi\/d\.\/d.\/d/ ascii
      $identifier2 = "Copyright (C) FBI Systems, 2012-2019, https://fbi.gov" fullword ascii
      $identifier3 = "God 5.1"

   condition:
      uint16(0) == 0x457f
      and
      (
         all of them
         or
         (
            any of ($identifier*)
            and $resolvers
            and any of ($tmp*)
            and 4 of ($str*)
         )
         or
         (
            any of ($identifier*)
            and any of ($tmp*)
            and 4 of ($str*)
         )
      )
}

