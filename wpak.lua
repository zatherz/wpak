local wak = require "wak"

local function printerr(...)
    local args = {...}
    args.n = select("#", ...)

    for i, v in ipairs(args) do
        io.stderr:write(tostring(v))
        if i ~= args.n then
            io.stderr:write("\t")
        end
    end

    io.stderr:write("\n")
end

local function usage()
    printerr("usage: wpak.lua pack some_directory/ foo.wak    -- creates foo.wak")
    printerr("   or: wpak.lua pack some_directory/            -- creates data.wak")
    printerr("   or: wpak.lua unpack data.wak some_directory/ -- unpacks data.wak into some_directory/")
    printerr("   or: wpak.lua unpack data.wak                 -- unpacks data.wak into current directory")
    printerr("   or: wpak.lua list data.wak                   -- lists all files in data.wak")
end

local cmd = arg[1]

if not cmd then
    printerr("error: no command was provided")
    printerr()
    usage()
    os.exit(1)
end

if cmd ~= "pack" and cmd ~= "unpack" and cmd ~= "list" then
    printerr("error: command '" .. cmd .. "' is not valid")
    printerr()
    usage()
    os.exit(1)
end

local file_exists, make_dir, is_dir, for_each_file_in

local ffi = require("ffi")
if ffi.os == "Windows" then
    ffi.cdef[[
        typedef struct _FILETIME {
          unsigned int dwLowDateTime;
          unsigned int dwHighDateTime;
        } FILETIME, *PFILETIME, *LPFILETIME;

        typedef struct _WIN32_FIND_DATAA {
          unsigned int    dwFileAttributes;
          FILETIME ftCreationTime;
          FILETIME ftLastAccessTime;
          FILETIME ftLastWriteTime;
          unsigned int    nFileSizeHigh;
          unsigned int    nFileSizeLow;
          unsigned int    dwReserved0;
          unsigned int    dwReserved1;
          char     cFileName[260]; // MAX_PATH == 260
          char     cAlternateFileName[14];
          unsigned int    dwFileType;
          unsigned int    dwCreatorType;
          unsigned short     wFinderFlags;
        } WIN32_FIND_DATAA, *PWIN32_FIND_DATAA, *LPWIN32_FIND_DATAA;

        // shlwapi
        bool __stdcall PathFileExistsA(const char* path);
        bool __stdcall PathIsDirectoryA(const char* path);

        // win32
        void* __stdcall FindFirstFileA(const char* dir_path, LPWIN32_FIND_DATAA find_file_data);
        bool __stdcall FindNextFileA(void* handle, LPWIN32_FIND_DATAA find_file_data);
        bool __stdcall FindClose(void* handle);
        unsigned int __stdcall GetLastError();

        // crt
        int _mkdir(const char* dirname);
    ]]

    local shlwapi = ffi.load("shlwapi.dll")
    local C = ffi.C

    file_exists = function(path)
        return shlwapi.PathFileExistsA(path)
    end

    -- https://docs.microsoft.com/en-us/cpp/c-runtime-library/reference/splitpath-wsplitpath?view=vs-2019
    local MAX_DRIVE = 3
    local MAX_DIR = 256
    local MAX_FNAME = 256
    local MAX_EXT = 256

    make_dir = function(path)
        local result = C._mkdir(path)
        if result == -1 then
            local errno = ffi.errno()
            if errno == 2 then -- ENOENT
                error("parent of path was not found: '" .. path .. "'")
            elseif errno == 17 then -- EEXIST
                error("file/directory already exists at: '" .. path .. "'")
            else
                error("unknown error when trying to create directory at: '" .. path .. "'")
            end
        end
    end

    is_dir = function(path)
        return shlwapi.PathIsDirectoryA(path)
    end
    
    local INVALID_HANDLE_VALUE = ffi.cast("void*", -1)

    for_each_file_in = function(path, f)
        local ffd = ffi.new("WIN32_FIND_DATAA[1]")

        path = path .. "\\*"
        -- for some reason win32 needs this
        -- absolutely ridiculous

        local handle = C.FindFirstFileA(path, ffd)

        if handle == INVALID_HANDLE_VALUE then
            error("failed entering directory '" .. path .. "'")
        end

        local status = true

        while status do
            local filename = ffi.string(ffd[0].cFileName)
            if filename ~= "." and filename ~= ".." then
                f(filename)
            end

            status = C.FindNextFileA(handle, ffd)
        end

        C.FindClose(handle)
    end
elseif ffi.os == "Other" then
    printerr("error: unsupported operating system")
    os.exit(1)
else
    ffi.cdef[[
        struct stat64 {
            unsigned long long	st_dev;
            unsigned char   __pad0[4];

            unsigned long	__st_ino;
            unsigned int	st_mode;
            unsigned int	st_nlink;

            unsigned long	st_uid;
            unsigned long	st_gid;

            unsigned long long	st_rdev;
            unsigned char   __pad3[4];

            long long	st_size;
            unsigned long	st_blksize;
            unsigned long long st_blocks;	/* Number 512-byte blocks allocated. */

            unsigned long	st_atime;
            unsigned long	st_atime_nsec;

            unsigned long	st_mtime;
            unsigned long	st_mtime_nsec;

            unsigned long	st_ctime;
            unsigned long	st_ctime_nsec;

            unsigned long long	st_ino;
        };

        struct dirent64 {
            uint64_t		d_ino;
            int64_t		d_off;
            unsigned short	d_reclen;
            unsigned char	d_type;
            char		d_name[];
        };

        int access(const char* path, int mode);
        int mkdir(const char* path, unsigned short mode);
        int __xstat64(int ver, const char* path, struct stat64* buf);
        void* opendir(const char* name);
        struct dirent64* readdir64(void* dir_stream);
        int closedir(void* dir_stream);
    ]]

    local C = ffi.C

    -- taken from /usr/include/unistd.h
    local R_OK = 4
    local W_OK = 2
    local X_OK = 1
    local F_OK = 0

    -- https://stackoverflow.com/a/54530853
    local XSTAT_VER = ffi.arch == "x64" and 1 or 3

    -- taken from /usr/include/bits/stat.h
    local S_IFMT = 0xf000 -- octal: 0170000	
    local S_IFDIR = 0x4000 -- octal: 0040000	
    -- translated from /usr/include/sys/stat.h
    local function stat_istype(mode, mask)
        return bit.band(mode, S_IFMT) == mask
    end

    local function stat_isdir(mode)
        return stat_istype(mode, S_IFDIR)
    end

    file_exists = function(path)
        return C.access(path, F_OK) ~= -1
    end

    make_dir = function(path)
        local result = C.mkdir(path, 0x1ed) -- 0x1ed = 755 in octal
        if result == -1 then
            local errno = ffi.errno()
            if errno == 2 then -- ENOENT
                error("parent of path was not found: '" .. path .. "'")
            elseif errno == 17 then -- EEXIST
                error("file/directory already exists at: '" .. path .. "'")
            else
                error("unknown error when trying to create directory at: '" .. path .. "'")
            end
        end
    end

    is_dir = function(path)
        local statbuf = ffi.new("struct stat64[1]")
        local result = C.__xstat64(XSTAT_VER, path, statbuf)
        if result ~= 0 then return false end
        return stat_isdir(statbuf[0].st_mode)
    end

    for_each_file_in = function(path, f)
        local dir_stream = C.opendir(path)
        if dir_stream == nil then
            error("failed entering directory '" .. path .. "'")
        end

        local dirent = C.readdir64(dir_stream)
        while dirent ~= nil do
            local filename = ffi.string(dirent.d_name)
            if filename ~= "." and filename ~= ".." then
                f(filename)
            end
            dirent = C.readdir64(dir_stream)
        end

        C.closedir(dir_stream)
    end
end

-- platform specific functions available after this point:
-- file_exists(path), make_dir(path),
-- is_dir(path), for_each_file_in(path, f : (path))

local function dir_name(path)
    local parent = string.match(path, "(.*)/[^/]*$")
    return parent or path
end

local function file_name(path)
    return string.match(path, "([^/]+)$")
end

local function pack_dir(archive, base_path, import_base_path)
    if not import_base_path then
        import_base_path = file_name(base_path)
    end

    for_each_file_in(base_path, function(file)
        local file_path = base_path .. "/" .. file
        local import_path = import_base_path .. "/" .. file
        if is_dir(file_path) then
            print("including directory: " .. import_path)
            pack_dir(archive, file_path, import_path)
        else
            print("including file: " .. import_path)
            archive:import(import_path, file_path)
        end
    end)
end

local function make_dir_recursive(base_dir, path)
    local path_elems = {}
    local i = 0
    for elem in string.gmatch(path, "([^/]+)") do
        i = i + 1
        path_elems[i] = elem
    end

    local sep = ffi.os == "Windows" and "\\" or "/"
    local cur_path = base_dir
    for elem_idx, elem in ipairs(path_elems) do
        if cur_path then
            cur_path = cur_path .. sep .. elem
        else
            cur_path = elem
        end

        if not is_dir(cur_path) and not file_exists(cur_path) then
            make_dir(cur_path)
        end
    end
end

if cmd == "pack" then
    local dir = arg[2]
    if not dir then
        printerr("error: missing directory")
        printerr()
        usage()
        os.exit(1)
    end
    local target = arg[3] or "data.wak"

    if file_exists(target) then
        printerr("note: file '" .. target .. "' already exists - overwriting")
    end

    local archive = wak.new()
    pack_dir(archive, dir)
    archive:write(target)
elseif cmd == "unpack" then
    local wak_path = arg[2]
    if not wak_path then
        printerr("error: missing wak file path")
        printerr()
        usage()
        os.exit(1)
    end

    local output_dir = arg[3] or "."
    if not file_exists(output_dir) then
        make_dir_recursive(nil, output_dir)
    end

    local archive = wak.open(wak_path)
    for file in archive:files() do
        local parent_dir = dir_name(file.path)
        make_dir_recursive(output_dir, parent_dir)
        print("extracting file: " .. file.path)
        archive:extract(file.path, output_dir .. "/" .. file.path)
    end
elseif cmd == "list" then
    local wak_path = arg[2]
    if not wak_path then
        printerr("error: missing wak file path")
        printerr()
        usage()
        os.exit(1)
    end

    local archive = wak.open(wak_path)
    for file in archive:files() do
        print(file.path)
    end
end
