# WPAK

WPAK is a third party program capable of packing and unpacking files in the Noita WizardPak (.wak) format. It is built on top of the [LuaWAK](https://github.com/zatherz/luawak) library and can extract as well as repack the game's assets archive `data.wak` into/from a directory. WPAK also allows you to easily create your own .wak archives unrelated to `data.wak`.

## Running

WPAK, just like LuaWAK, requires LuaJIT to run. Simply download or build LuaJIT, and then run it like this:

```
luajit wpak.lua
```

WPAK has been tested on both Linux and Windows.

## Usage

To display examples of usage at any time, you can simply run `wpak.lua` with no arguments.

```
usage: wpak.lua pack some_directory/ foo.wak    -- creates foo.wak
   or: wpak.lua pack some_directory/            -- creates data.wak
   or: wpak.lua unpack data.wak some_directory/ -- unpacks data.wak into some_directory/
   or: wpak.lua unpack data.wak                 -- unpacks data.wak into current directory
   or: wpak.lua list data.wak                   -- lists all files in data.wak
```

## LuaWAK

Please note that this repository includes a bundled copy of the [LuaWAK](https://github.com/zatherz/luawak) library. You can choose to use a newer version at any time by simply replacing the `wak.lua` file with one from a newer version of the library.
