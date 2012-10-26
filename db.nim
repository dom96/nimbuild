# This module is used by the website.
import redis, times, strutils
from sockets import TPort

type
  TDb* = object
    r*: TRedis
    lastPing: float

  TBuildResult* = enum
    bUnknown, bFail, bSuccess

  TTestResult* = enum
    tUnknown, tFail, tSuccess

  TEntry* = tuple[c: TCommit, p: seq[TPlatform]]
  
  TCommit* = object
    commitMsg*, username*, hash*, branch*: string
    date*: TTime

  # TODO: rename to TBuild?
  TPlatform* = object
    buildResult*: TBuildResult
    testResult*: TTestResult
    failReason*, platform*: string
    total*, passed*, skipped*, failed*: biggestInt
    csources*: bool

const
  listName = "commits"
  failOnExisting = False

proc open*(host = "localhost", port: TPort): TDb =
  result.r = redis.open(host, port)
  result.lastPing = epochTime()

proc customHSet(database: TDb, name, field, value: string) =
  if database.r.hSet(name, field, value).int == 0:
    if failOnExisting:
      assert(false)
    else:
      echo("[Warning:REDIS] ", field, " already exists in ", name)

proc updateProperty*(database: TDb, commitHash, platform, property,
                    value: string) =
  var name = platform & ":" & commitHash
  if database.r.hSet(name, property, value).int == 0:
    echo("[INFO:REDIS] '$1' field updated in hash" % [property])
  else:
    echo("[INFO:REDIS] '$1' new field added to hash" % [property])

proc globalProperty*(database: TDb, commitHash, property, value: string) =
  if database.r.hSet(commitHash, property, value).int == 0:
    echo("[INFO:REDIS] '$1' field updated in hash" % [property])
  else:
    echo("[INFO:REDIS] '$1' new field added to hash" % [property])

proc addCommit*(database: TDb, commitHash, commitMsg, user, branch: string) =
  # Add the commit hash to the `commits` list.
  discard database.r.lPush(listName, commitHash)
  # Add the commit message, current date and username as a property
  globalProperty(database, commitHash, "commitMsg", commitMsg)
  globalProperty(database, commitHash, "date", $int(getTime()))
  globalProperty(database, commitHash, "username", user)
  globalProperty(database, commitHash, "branch", branch)

proc keepAlive*(database: var TDb) =
  ## Keep the connection alive. Ping redis in this case. This functions does
  ## not guarantee that redis will be pinged.
  var t = epochTime()
  if t - database.lastPing >= 60.0:
    echo("PING -> redis")
    assert(database.r.ping() == "PONG")
    database.lastPing = t

proc getCommits*(database: TDb,
                 plStr: var seq[string]): seq[TEntry] =
  result = @[]
  var commitsRaw = database.r.lrange("commits", 0, -1)
  for c in items(commitsRaw):
    var commit: TCommit
    commit.hash = c
    for key, value in database.r.hPairs(c):
      case normalize(key)
      of "commitmsg": commit.commitMsg = value
      of "date": commit.date = TTime(parseInt(value))
      of "username": commit.username = value
      of "branch": commit.branch = value
      else:
        echo("[redis] Key not found: ", key)
        assert(false)

    var platformsRaw = database.r.lrange(c & ":platforms", 0, -1)
    var platforms: seq[TPlatform] = @[]
    for p in items(platformsRaw):
      var platform: TPlatform
      for key, value in database.r.hPairs(p & ":" & c):
        case normalize(key)
        of "buildresult":
          platform.buildResult = parseInt(value).TBuildResult
        of "testresult":
          platform.testResult = parseInt(value).TTestResult
        of "failreason":
          platform.failReason = value
        of "total":
          platform.total = parseBiggestInt(value)
        of "passed":
          platform.passed = parseBiggestInt(value)
        of "skipped":
          platform.skipped = parseBiggestInt(value)
        of "failed":
          platform.failed = parseBiggestInt(value)
        of "csources":
          platform.csources = if value == "t": true else: false
        else:
          echo("[redis] platf key not found: " & normalize(key))
          assert(false)
      
      platform.platform = p
      
      platforms.add(platform)
      if p notin plStr:
        plStr.add(p)
    result.add((commit, platforms))

proc commitExists*(database: TDb, commit: string, starts = false): bool =
  # TODO: Consider making the 'commits' list a set.
  for c in items(database.r.lrange("commits", 0, -1)):
    if starts:
      if c.startsWith(commit): return true
    else:
      if c == commit: return true
  return false

proc platformExists*(database: TDb, commit: string, platform: string): bool =
  for p in items(database.r.lrange(commit & ":" & "platforms", 0, -1)):
    if p == platform: return true

proc expandHash*(database: TDb, commit: string): string =
  for c in items(database.r.lrange("commits", 0, -1)):
    if c.startsWith(commit): return c
  assert false

proc isNewest*(database: TDb, commit: string): bool =
  return database.r.lIndex("commits", 0) == commit

proc getNewest*(database: TDb): string =
  return database.r.lIndex("commits", 0)

proc addPlatform*(database: TDb, commit: string, platform: string) =
  assert database.commitExists(commit)
  assert (not database.platformExists(commit, platform))
  var name = platform & ":" & commit
  if database.r.exists(name):
    if failOnExisting: quit("[FAIL] " & name & " already exists!", 1)
    else: echo("[Warning] " & name & " already exists!")

  discard database.r.lPush(commit & ":" & "platforms", platform)

proc `[]`*(p: seq[TPlatform], name: string): TPlatform =
  for platform in items(p):
    if platform.platform == name:
      return platform
  raise newException(EInvalidValue, name & " platforms not found in commits.")
  
proc contains*(p: seq[TPlatform], s: string): bool =
  for i in items(p):
    if i.platform == s:
      return True

