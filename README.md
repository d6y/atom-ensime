# atom-ensime

This is a work in progress to try to use Ensime functionality in Atom.io

1. sbt ensime (to generate .ensime file)
2. Start ensime server on the project. For now you need to use Emacs to get your script.
    start-server.sh is mine (Viktor's) hardcoded for now
3. ctrl-shift-p "Ensime: init project"
4. ctrl-shift-p "Ensime: go to definition"


## Dev
"Window: reload" (ctrl-option-cmd l) to reload plugin from source while developing

## Google group thread:
https://groups.google.com/forum/#!searchin/ensime/log/ensime/1dWUQwnFoyk/0O12KPjaIBgJ


## Technical TODO:
- [x] checkout typescript plugin for hover for type info
- [ ] See if we can use code-links for mouse clicks https://atom.io/packages/code-links


## Features TODO:

- [x] jump to definition
- [x] key shortcuts
- [x] hover (or something) for type info
- [ ] get server "bundled" the same way Emacs does it
- [ ] mouse interaction (cmd-click for jump to definition)
- [ ] errors and warnings
- [ ] autocompletion
- [ ] view applied implicits
