import asyncdispatch, asyncnet, logging, json

import common/client

proc onMessage(client: Client, message: JsonNode) {.async.} =
  debug("onMessage")

when isMainModule:
  # Set up logging.
  var console = newConsoleLogger(fmtStr = verboseFmtStr)
  handlers.add(console)

  var builderClient = newClient("builder", onMessage)
  waitFor builderClient.start("localhost", Port(5123))
