# Structure
                    
         Github
             \
              \
               Hub --------- Builder A, B, C
                  \
                   \
                   NimBot

## The Hub a.k.a "the website"

This serves the website, it also acts as a hub, all the "modules" connect to it.

## Builder

There are many of these connected at once to the Hub. Each runs on a different
platform.

Its job is to wait for a new commit notification from the hub. When this event
occurs, it will update the local Nimrod git repository and begin the build
process.

The build process consists of the following:

* Downloading the current C sources and building from them if they changed.
* Bootstrapping the Nimrod compiler in debug and release mode.
* Running the test suite.
* Building the C sources (one builder only)
* Building the documentation (one builder only)

While doing so the builder keeps the hub updated with the progress of the build.
The build is separated into jobs which include ``JBuild``, ``JTest``, 
``JCSrcGen``, ``JDocGen`` and ``JInnoGen``. The jobs are not run in parallel,
and if one fails the rest fail. 

## Github

This module waits for a request from Github which notifies it that there is a 
new commit in Nimrod's repo. It passes this information on to the hub.

The hub uses this information to do multiple things including:

* Sending the information to NimBot so that it announces the commit in the IRC channel.
* Notifying the connected builders that a new commit is ready to be built.

## NimBot

This is the IRC bot that resides in #nimrod on Freenode. It announces new commits
to the Nimrod repo (and other nimrod-related repos) in that channel. It also
announces build info in the #nimbuild channel.

Other features include:

* !seen <nick> feature

## Communication

The hub communicates with the modules that are connected to it using JSON and
vice versa; the modules do the same.

### Hub

The hub currently supports the following messages:

#### ``{ "job": types.TBuilderJob.ord }``

This marks the start of a new build job.

**Sent by:** builder.

#### ``{ "result": system.TResult.ord }``

Finishes the current builder's job with ``result`` (either success or failure).

Other params:

* ``detail`` - When ``result`` is ``Failure`` this contains the reason as to the
  failure.
* ``total``/``passed``/``skipped``/``failed`` - When the current job is ``JTest``
  and ``result`` is ``Success`` these fields contain the total tests, and also
  the amount of passed, skipped and failed tests.

**Sent by:** builder.

#### ``{ "eventType": TBuilderEventType.ord }`` 

Updates the hub on the status of a build in progress.

**Sent by:** builder.

#### ``{ "payload": { ... } }``

Tells the hub about a new commit or multiple commits made to a repo.
Not necessarily the Nimrod repo.

**Sent by:** github

#### ``{ "latestCommit": true }``

Requests info about the latest commit from the hub.

**Sent by:** builder.

#### ``{ "ping": TimeSinceUnixEpoch }``

A module is verifying that it's still connected.

**Sent by:** All modules.

#### ``{ "pong": TimeSinceUnixEpoch }``

A module is replying to a "ping" message from the hub.

**Sent by:** All modules.

#### ``{ "do": "request" }``

A module is asking for info.

##### ``redisinfo``

Sends redis db info to the module requesting it.

**Sent by:** NimBot.

# Database

The current database that is being used is redis.

## Structure

Here is a brief description of the current database which is to be deprecated.

### A list

This will be called ``commits``. Each commit hash will be LPUSH-ed onto this list for easy iteration from the latest to the oldest commits with LRANGE.

### Keys

Information about each commit will be saved in a hash by the name of ``commit_hash``.
The fields will be:
  * commitMsg
  * date
  * username
  * branch

Specific information about a build can be retrieved by accessing ``platform:commit_hash``, where ``platform`` can be for example "linux-x86".
The fields that these will contain will be:
  * buildResult -> db.TBuildResult ( bUnknown, bFail, bSuccess )
  * testResult  -> db.TTestResult  ( tUnknown, tFail, tSuccess )
  * total       -> total tests
  * passed      -> passed tests
  * skipped     -> skipped tests
  * failed      -> failed tests
  * csources    -> whether the csources have been built for this platform/commit combination ("t" or "f" (?))
  * timeBuild   -> Time taken to build TODO
  * timeTest    -> Time taken to test

