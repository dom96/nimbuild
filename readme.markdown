# Nimbuild

This is the Nim build farm. It is separated into multiple components; main one being
the website (website.nim); which acts as a ``hub`` for all the other components
- they all connect to it. It also acts as the front end and is available at
http://build.nim-lang.org/. 

The other components:

### Github.nim
This component waits for connections from github, it acts as a POST receive hook.
It waits for a POST request from github containing a payload informing it
of the file commited to the Nim repo, it then sends this information on
to the website.

### Builder.nim
This component does the actual building, multiple instances of it run on different
platforms. It pulls the latest version of the compiler from github, bootstraps
it, zips the binary then uploads the zip to nimbuild. It then finally runs
the test suite. It also does some other tasks which are optional, like generating
c sources and the documentation.

### ircbot.nim
This component is an IRC bot which idles in the #nim channel on freenode, it
has some features already. It's main purpose is to announce a commit in the
channel, but it also has a !seen command. More features are planned for later.

## Contributing
Pull requests are always welcome. If you are not much of a programmer you can
always donate a machine, we are always looking for new machines, especially
Windows ones to run nimbuild on, if you have one please contact me on Github
or on freenode (i'm dom96).
