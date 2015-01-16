import parsecfg, strtabs, streams, strutils

## This module gets rid of the boilerplate of parsecfg.

type
  Config* = distinct StringTableRef

proc newConfig*(): Config =
  newStringTable().Config

proc parse*(filename: string): Config =
  var table = newStringTable()
  var f = newFileStream(filename, fmRead)
  if f != nil:
    var p: CfgParser
    open(p, f, filename)
    var section = ""
    while true:
      var e = next(p)
      case e.kind
      of cfgEof: 
        break
      of cfgSectionStart:
        section = e.section
      of cfgKeyValuePair, cfgOption:
        if section != "":
          table[section & "." & e.key] = e.value
        else:
          table[e.key] = e.value
      of cfgError:
        raise newException(ValueError, e.msg)
    close(p)
  else:
    raise newException(ValueError, "File not found: " & filename)
  result = table.Config

proc `[]`*(config: Config, x: string): string =
  (config.StringTableRef)[x]

proc get*(config: Config, x: string, def = ""): string =
  let table = config.StringTableRef
  if table.hasKey(x):
    return table[x]
  else:
    return def

proc getInt*(config: Config, x: string, def = 0): int =
  let table = config.StringTableRef
  if table.hasKey(x):
    return table[x].parseInt
  else:
    return def
