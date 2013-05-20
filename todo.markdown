* Move from redis to mongodb or sqlite(?)
  * Convert redis data to suit the current website layout.
* Hub should only have the FTP info, builders should query it for this data.
* Download table is broken.
* Keep only the latest version of Nimrod for download.
* grep "TODO"
* Fix nimbot
* Integration with Github status API
  * When a pull request is made nimbuild should be intelligent on what it compiles
    I.e. If the file edited is in the compiler/ directory then nimrod should be bootstrapped
    if the file edited is a test, the test should be ran
    if the file edited is a module in the stdlib it should just be compiled
    * This should then be reported to github...

* Nimbuild should be smart, as described above, this should be replicated to
  all pushes. Single file change: build only that file, compiler changes do whole bootstrap + test suite.
  etc.
  * If the newest build only built one file, the website should show the last known test results (perhaps with a warning).
    * DB needs to know about this.

* Inspect diff.
  * If all lines that were changed start with (\s+)## then no need to bootstrap,
    just ened to rebuild the docs.

* Change the left side color of each platform box to show the current builder status.
  * Pulsates blue when building
  * Red when disconnected
  * Blue when connected?
  
* .deb gen