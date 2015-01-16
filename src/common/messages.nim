import json, logging

proc genMessage*(event: string,
                 args: JsonNode): string =
  $(%{"event": %event, "args": args}) & "\c\l"

proc parseMessage*(message: string): JsonNode =
  ## Returns ``JNull`` if message is invalid.
  try:
    parseJson(message)
  except:
    warn("Message could not be parsed: " & getCurrentExceptionMsg())
    debug("Message was: " & message)
    newJNull()

proc getStr*(node: JsonNode, def = ""): string =
  if node.isNil: return def
  if node.kind != JString: return def
  else: return node.str

proc getFloat*(node: JsonNode, def = 0.0): float =
  if node.isNil: return def
  if node.kind != JFloat: return def
  else: return node.fnum
