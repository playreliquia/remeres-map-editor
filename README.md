What is this?
=============

This is a map editor for OpenTibia, which is an open source implementation of the MMORPG Tibia (which can be found at [tibia.com](http://tibia.com)).
You can find the project for hosting your own server at [Canary](https://github.com/opentibiabr/canary).

Getting Started
=========
* [Wiki](https://github.com/opentibiabr/remeres-map-editor/wiki).
* [Cyclopedia export documentation](docs/static-data.md).

Building
========

[mise](https://mise.jdx.dev/getting-started.html) installs CMake, Ninja, the compiler cache and the lint tools at the versions pinned in `.mise/config.toml`, then drives the build:

```bash
mise run setup    # clone vcpkg at the vcpkg.json baseline, add the upstream remote
mise run dev      # build the debug editor and start it
mise run build    # configure and build the release preset for this OS
mise run package  # zip the release editor with data/, brushes/, icons/ and LICENSE.rtf into dist/
```

mise does not install the compiler or the system libraries:

* Linux: GCC 14 (`g++-14` on Ubuntu 24.04, which the build tasks select) and the `apt install` line in the [Ubuntu 24.04 guide](docs/building/ubuntu-24.04.md), which includes the GTK 3 headers wxWidgets builds against.
* Windows: Visual Studio 2026 with the C++ workload. Run mise from Git Bash; the build tasks load the MSVC environment themselves.
* macOS: the Xcode Command Line Tools.

On Windows with WSL, clone the repository onto the WSL disk (`~/...`), not under `/mnt/*`: builds across the Windows drive bridge run several times slower. In VS Code, open that clone through the WSL extension and press F5. The `build:dev` task builds the `linux-debug` preset, and gdb starts the editor through WSLg.

`mise tasks` lists the rest. The [per-platform guides](docs/building/README.md) cover the manual build without mise.

I want to contribute
====================

Contributions are very welcome, if you would like to make any changes, fork this project and create a pull request in our [pull request tracker](https://github.com/opentibiabr/remeres-map-editor/pulls).

Bugs
======

Have you found a bug? Please create an issue in our [bug tracker](https://github.com/opentibiabr/remeres-map-editor/issues).

Other Applications
==========

* To host your MMORPG game server, you can use [Canary](https://github.com/opentibiabr/canary).
* To play your MMORPG game, you can use [OTClient](https://github.com/mehah/otclient).
* To map your MMORPG game, you can use this map editor.

Download
========

You can find the releases in [opentibiabr remere's map editor](https://github.com/opentibiabr/remeres-map-editor/releases).
