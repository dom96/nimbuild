import asyncdispatch, asyncnet, logging

import common/client

proc onMessage(client: Client, message: JsonNode) {.async.} =
  debug("onMessage")

when isMainModule:
  # Set up logging.
  var console = newConsoleLogger(fmtStr = verboseFmtStr)
  handlers.add(console)

  var client = newClient("builder", onMessage)
  client.start("localhost", Port(5123))
