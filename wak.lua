local wak = {}

local ffi = require("ffi")
ffi.cdef[[
void* fopen(const char* filename, const char* mode);
size_t fwrite(void* ptr, size_t size, size_t count, void* stream);
size_t fread(void* ptr, size_t size, size_t count, void* stream);
long int ftell(void* stream);
int fseek(void* stream, long int offset, int origin);
void fclose(void* stream);
int ferror(void* stream);
int feof(void* stream);
void* memcpy(void* dest, void* src, size_t num);
]]

local function check_arg(name, expected_type, val)
    local t = type(val)
    if t ~= expected_type then
        if expected_type:sub(-1, -1) == "?" then
            return
        end
        error(
            "invalid type for argument "
            .. tostring(name)
            .. ": expected "
            .. tostring(expected_type)
            .. ", got "
            .. t
        )
    end
end

local function safe_fread(ptr, size, count, stream)
    local count_read = ffi.C.fread(ptr, size, count, stream);
    if count_read ~= count then
        -- for our purposes, both unexpected eof and actual error are errors
        if ffi.C.ferror(stream) ~= 0 or ffi.C.feof(stream) ~= 0 then
            error(
                "archive is corrupted - unexpected end of stream (tried reading "
                .. tostring(count)
                .. " byte(s), but only received "
                .. tostring(count_read)
                .. ")"
            )
        end
    end
    return count_read
end

local function safe_fopen(path, mode, lenient)
    local fd = ffi.C.fopen(path, mode)
    if lenient then return fd end
    if fd == nil then
        error(
            "file doesn't exist: '"
            .. tostring(path)
            .. "'"
        )
    end
    return fd
end

local ALLOC_SIZE_LIMIT = 128 * 1024 * 1024 -- 128MB ought to be enough for everybody
local function check_junk_size(size, what)
    if size > ALLOC_SIZE_LIMIT then
        error(
        "archive is corrupted - unexpectedly large reported length of "
        .. what
        .. " ("
        .. tostring(size)
        .. "), maximum allowed is 128MB" 
        )
    end
end

local INT_SIZE = ffi.sizeof("int")

local WAK_FUNCS = {}
local WAK_MT = {
    __index = WAK_FUNCS,
    __tostring = function(self)
        return "wak archive: " .. self.path
    end
}

local WAK_FILE_FUNCS = {}
local WAK_FILE_MT = {
    __index = WAK_FILE_FUNCS,
    __tostring = function(self)
        return "wak file: " .. self.path
    end
}

local function read_toc(wak, predicate)
    for i = wak._read_files, wak._num_files - 1 do
        local offs = ffi.new("int[1]")
        safe_fread(offs, INT_SIZE, 1, wak._stream)
        offs = offs[0]
        wak._pos = wak._pos + INT_SIZE

        local length = ffi.new("int[1]")
        safe_fread(length, INT_SIZE, 1, wak._stream)
        length = length[0]
        wak._pos = wak._pos + INT_SIZE

        local path_length = ffi.new("int[1]")
        safe_fread(path_length, INT_SIZE, 1, wak._stream)
        path_length = path_length[0]
        wak._pos = wak._pos + INT_SIZE

        check_junk_size(path_length, "path of file " .. tostring(tonumber(offs) + 1))
        local path_bytes = ffi.new("char[?]", path_length)
        safe_fread(path_bytes, ffi.sizeof("char"), path_length, wak._stream)
        wak._pos = wak._pos + path_length
        local path = ffi.string(path_bytes, path_length)

        local file = setmetatable({
            _wak = wak,
            _offset = offs,
            length = length,
            path = path,

            _content = nil
            -- if this is set, it should contain
            -- a lua string, which will override
            -- the behavior of functions such as
            -- read()
        }, WAK_FILE_MT)
        local existing_file = wak._files[path]
        if not existing_file then
            -- we don't care if it's a _removed entry
            -- here, because we also want to avoid
            -- overwriting those (otherwise sometimes
            -- :remove would just not work)
            wak._files[path] = file
        end

        wak._read_files = wak._read_files + 1

        if predicate and predicate(file) then
            break
        end
    end

    return contents
end

function wak.open(path, lenient)
    check_arg("path", "string", path)
    check_arg("lenient", "boolean?", lenient)

    if path:sub(-4, -1) ~= ".wak" then
        error("archive path must end with .wak extension: '" .. path .. "'")
    end

    local wak_f = safe_fopen(path, "rb", lenient)
    if wak_f == nil then return nil end

    ffi.C.fseek(wak_f, INT_SIZE, 0)
    local num_files = ffi.new("int[1]")
    safe_fread(num_files, INT_SIZE, 1, wak_f)
    num_files = num_files[0]
    local toc_size = ffi.new("int[1]")
    safe_fread(toc_size, INT_SIZE, 1, wak_f)
    toc_size = toc_size[0]
    ffi.C.fseek(wak_f, 4, 1)

    local ar_table = setmetatable({
        path = path,
        _stream = wak_f,
        _num_files = num_files,
        _toc_size = toc_size,
        _pos = INT_SIZE * 4,
        _read_files = 0,
        _files = {},
        _should_rebuild = false
    }, WAK_MT)

    local ar_proxy = newproxy(true)
    local ar_proxy_mt = getmetatable(ar_proxy)

    ar_proxy_mt.__gc = function(self)
        ar_table:dispose()
    end

    ar_proxy_mt.__index = ar_table
    ar_proxy_mt.__newindex = ar_table
    ar_proxy_mt.__tostring = function(self)
        return tostring(ar_table)
    end

    return ar_proxy
end

function wak.new()
    return setmetatable({
        path = "(memory)",
        _stream = nil,
        _num_files = 0,
        _toc_size = 0,
        _pos = 0,
        _read_files = 0,
        _files = {},
        _should_rebuild = true
    }, WAK_MT)
end

local function check_disposed(wak)
    if wak._disposed then error("cannot operate on disposed archive") end
end

function WAK_FUNCS:preload_all()
    check_disposed(self)
    if not self._stream then
        return
    end
    read_toc(self)
end

function WAK_FUNCS:open(path)
    check_disposed(self)
    check_arg("path", "string", path)
    
    local existing_file = self._files[path]
    if existing_file ~= nil then
        if existing_file._removed then return nil end
        return existing_file
    end

    if self._stream then
        read_toc(self, function(file) return file.path == path end)
    end
    return self._files[path]
end

function WAK_FUNCS:extract(path, out_path)
    check_disposed(self)
    check_arg("path", "string", path)
    check_arg("out_path", "string", out_path)

    local existing_file = self._files[path]
    if existing_file then
        if existing_file._removed then
            error("File was removed from the archive: " .. path)
        end
        existing_file:write(out_path)
        return
    end

    if not self._stream then return end

    local found = false
    read_toc(function(file)
        if file.path == path then
            found = true
            file:write(out_path)

            return true
        end
    end)

    if not found then
        error("File doesn't exist in the archive: " .. path)
    end
end

function WAK_FUNCS:add(path, content)
    check_disposed(self)
    check_arg("path", "string", path)
    check_arg("content", "string", content)

    self:preload_all()
    local existing_file = self._files[path]
    if existing_file and not existing_file._removed then
        error(
            "wak file already exists: '"
            .. path
            .. "'"
        )
    end
    return self:set(path, content)
end

function WAK_FUNCS:set(path, content)
    check_disposed(self)
    check_arg("path", "string", path)
    check_arg("content", "string", content)

    local memory_file = setmetatable({
        _wak = self,
        path = path,
        length = #content,
        _content = content
        -- _content overrides the default behavior
        -- of reading the file
    }, WAK_FILE_MT)

    self._should_rebuild = true
    -- if a file is added to the wak (or changed),
    -- writing it is no longer just a simple
    -- bytewise copy

    self._files[path] = memory_file
    return memory_file
end

function WAK_FUNCS:import(path, imp_path)
    check_disposed(self)
    check_arg("path", "string", path)
    check_arg("imp_path", "string", imp_path)

    local imp_f = safe_fopen(imp_path, "rb")
    ffi.C.fseek(imp_f, 0, 2)
    local imp_len = ffi.C.ftell(imp_f)
    ffi.C.fseek(imp_f, 0, 0)
    local buf = ffi.new("const char[?]", imp_len)
    safe_fread(ffi.cast("void*", buf), 1, imp_len, imp_f)
    ffi.C.fclose(imp_f)

    return self:set(path, ffi.string(buf, imp_len))
end

function WAK_FUNCS:remove(path)
    check_disposed(self)
    check_arg("path", "string", path)

    self._files[path] = { _removed = true }
end

function WAK_FUNCS:count_files()
    check_disposed(self)

    local count = 0
    self:preload_all()
    for k, v in pairs(self._files) do
        if not v._removed then
            count = count + 1
        end
    end
    return count
end

function WAK_FUNCS:files()
    check_disposed(self)

    self:preload_all()
    local gen, state, k = pairs(self._files)

    local function files_gen()
        local v
        repeat
            k, v = gen(state, k) 
        until k == nil or not v._removed

        if k ~= nil then
            return v
        end
    end

    return files_gen
end

local function wak_file_get_buf(self)
    local buf
    if self._content then
        buf = ffi.cast(
            "void*",
            ffi.cast("const char*", self._content)
        )
    else
        ffi.C.fseek(self._wak._stream, self._offset, 0)
        check_junk_size(self.length, "file " .. self.path)
        buf = ffi.new("char[?]", self.length)
        safe_fread(buf, ffi.sizeof("char"), self.length, self._wak._stream)
    end
    return buf
end

local function build_archive(wak)
    -- we will first get the total size of the buffer
    -- then iterate again
    -- it's simpler than dynamically reallocating
    -- and probably actually faster despite the extra
    -- loop

    local header_size = 4 * INT_SIZE
    local buf_size = header_size -- for the header
    local file_count = 0
    local toc_size = 0
    for path, file in pairs(wak._files) do
        if not file._removed then
            file_count = file_count + 1
            local toc_delta = INT_SIZE * 3 + #file.path
            toc_size = toc_size + toc_delta
            buf_size = buf_size + toc_delta + file.length
            -- offset, length, pathlength, path, and 
            -- finally content (in the block later)
        end
    end

    local buf = ffi.new("char[?]", buf_size)
    
    local header_unknown_1_ptr = ffi.cast("int*", buf + 0 * INT_SIZE)
    local num_files_ptr = ffi.cast("int*", buf + 1 * INT_SIZE)
    local toc_size_ptr = ffi.cast("int*", buf + 2 * INT_SIZE)
    local header_unknown_2_ptr = ffi.cast("int*", buf + 3 * INT_SIZE)

    header_unknown_1_ptr[0] = 0
    num_files_ptr[0] = file_count
    toc_size_ptr[0] = toc_size
    header_unknown_2_ptr[0] = 0

    local offset = header_size + toc_size
    local buf_offs = header_size -- skip header
    for path, file in pairs(wak._files) do 
        if not file._removed then
            local offs_ptr = ffi.cast("int*", buf + buf_offs + 0 * INT_SIZE)
            local length_ptr = ffi.cast("int*", buf + buf_offs + 1 * INT_SIZE)
            local pathlen_ptr = ffi.cast("int*", buf + buf_offs + 2 * INT_SIZE)
            local path_ptr = buf + buf_offs + 3 * INT_SIZE

            offs_ptr[0] = offset
            length_ptr[0] = file.length
            pathlen_ptr[0] = #file.path

            local path_buf = ffi.cast("const char*", file.path)
            for i = 0, #file.path - 1 do
                path_ptr[i] = path_buf[i]
            end

            offset = offset + file.length
            buf_offs = buf_offs + 3 * INT_SIZE + #file.path
        end
    end

    local i = 0
    for path, file in pairs(wak._files) do
        if not file._removed then
            i = i + 1
            local file_buf = wak_file_get_buf(file)
            ffi.C.memcpy(buf + buf_offs, file_buf, file.length)
            buf_offs = buf_offs + file.length
        end
    end

    return { buf = buf, buf_size = buf_size }
end

local function write_wak(self, out_path, dispose)
    self:preload_all()

    if not dispose and out_path == self.path then
        error(
            "Archive '"
            .. self.path
            .. "' may not be written to the same path "
            .. "without using :write_and_dispose"
        )
    end

    local buf = nil
    local buf_size = 0
    if self._should_rebuild then
        local ar = build_archive(self, f)
        buf = ar.buf
        buf_size = ar.buf_size
    else
        ffi.C.fseek(self._stream, 0, 2)
        buf_size = ffi.C.ftell(self._stream)
        check_junk_size(buf_size, "size of archive on disk")
        ffi.C.fseek(self._stream, 0, 0)
        buf = ffi.new("char[?]", buf_size)

        safe_fread(buf, 1, buf_size, self._stream)
        ffi.C.fseek(self._stream, self._pos, 0)
    end

    if dispose then
        self:dispose()
    end
    local f = safe_fopen(out_path, "wb")

    ffi.C.fwrite(buf, 1, buf_size, f)
    ffi.C.fclose(f)
end

function WAK_FUNCS:force_rebuild_on_write()
    check_disposed(self)
    self._should_rebuild = true
end

function WAK_FUNCS:write(out_path)
    check_disposed(self)
    check_arg("out_path", "string", out_path)

    write_wak(self, out_path, false)
end

function WAK_FUNCS:write_and_dispose(out_path)
    check_disposed(self)
    check_arg("out_path", "string", out_path)

    write_wak(self, out_path, true)
end

function WAK_FUNCS:dispose()
    if not self._disposed then
        ffi.C.fclose(self._stream)
    end
    self._disposed = true
end

function WAK_FILE_FUNCS:read()
    check_disposed(self._wak)

    if self._content then
        return self._content
    end

    ffi.C.fseek(self._wak._stream, self._offset, 0)
    check_junk_size(self.length, "file " .. self.path)
    local buf = ffi.new("char[?]", self.length)
    safe_fread(buf, ffi.sizeof("char"), self.length, self._wak._stream)
    ffi.C.fseek(self._wak._stream, self._wak._pos, 0)
    return ffi.string(buf, self.length)
end

function WAK_FILE_FUNCS:write(out_path)
    check_disposed(self._wak)

    local buf = wak_file_get_buf(self)

    local out_f = safe_fopen(out_path, "w")
    ffi.C.fwrite(buf, ffi.sizeof("char"), self.length, out_f)

    ffi.C.fclose(out_f)
end

return wak
