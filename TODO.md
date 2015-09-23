# TODO list

 - extend to handle more kinds of deprecations
   - e.g. `dies_ok` and `lives_ok` should be `dies-ok` and `lives-ok`
     respectively.
   - `.for` has been replaced by `.flatmap`
   - kebab-case names.  E.g.: `use MONKEY_TYPING` -> `use MONKEY-TYPING`
   - `IO::Handle.slurp` -> `IO::Handle.slurp-rest`



 - have a database (json?) of deprecations
 - download list of all known modules
 - for each module clone module (if not already cloned)
 - use git API (handle authentication nicely)
 - handle git and http protocols
 - if cloned, update clone
 - update clone:
   - change to master
   - stash changes
   - fetch from upstream
   - merge with master
   - change back to original branch
   - unstash changes
 - when to fork exactly?  When a deprecated feature appears?
