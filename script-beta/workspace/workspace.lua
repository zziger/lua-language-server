local pub        = require 'pub'
local fs         = require 'bee.filesystem'
local furi       = require 'file-uri'
local files      = require 'files'
local config     = require 'config'
local glob       = require 'glob'
local platform   = require 'bee.platform'
local await      = require 'await'
local rpath      = require 'workspace.require-path'

local m = {}
m.type = 'workspace'
m.nativeVersion = -1
m.libraryVersion = -1
m.nativeMatcher = nil
m.uri = ''
m.path = ''
m.requireCache = {}

--- 初始化工作区
function m.init(uri)
    m.uri  = uri
    m.path = m.normalize(furi.decode(uri))
    log.info('Workspace inited: ', uri)
    local logPath = ROOT / 'log' / (uri:gsub('[/:]+', '_') .. '.log')
    log.info('Log path: ', logPath)
    log.init(ROOT, logPath)
end

--- 创建排除文件匹配器
function m.getNativeMatcher(option, interface)
    if m.nativeVersion == config.version then
        return m.nativeMatcher
    end

    local pattern = {}
    -- config.workspace.ignoreDir
    for path in pairs(config.config.workspace.ignoreDir) do
        log.info('Ignore directory:', path)
        pattern[#pattern+1] = path
    end
    -- config.files.exclude
    for path, ignore in pairs(config.other.exclude) do
        if ignore then
            log.info('Ignore by exclude:', path)
            pattern[#pattern+1] = path
        end
    end
    -- config.workspace.ignoreSubmodules
    if config.config.workspace.ignoreSubmodules then
        local buf = pub.awaitTask('loadFile', furi.encode(m.path .. '/.gitmodules'))
        if buf then
            for path in buf:gmatch('path = ([^\r\n]+)') do
                log.info('Ignore by .gitmodules:', path)
                pattern[#pattern+1] = path
            end
        end
    end
    -- config.workspace.useGitIgnore
    if config.config.workspace.useGitIgnore then
        local buf = pub.awaitTask('loadFile', furi.encode(m.path .. '/.gitignore'))
        if buf then
            for line in buf:gmatch '[^\r\n]+' do
                log.info('Ignore by .gitignore:', line)
                pattern[#pattern+1] = line
            end
        end
    end
    -- config.workspace.library
    for path in pairs(config.config.workspace.library) do
        log.info('Ignore by library:', path)
        pattern[#pattern+1] = path
    end

    m.nativeMatcher = glob.gitignore(pattern, option, interface)

    m.nativeVersion = config.version
    return m.nativeMatcher
end

--- 创建代码库筛选器
function m.getLibraryMatchers(option)
    if m.libraryVersion == config.version then
        return m.libraryMatchers
    end

    m.libraryMatchers = {}
    for path, pattern in pairs(config.config.workspace.library) do
        local nPath = fs.absolute(fs.path(path)):string()
        local matcher = glob.gitignore(pattern, option)
        if platform.OS == 'Windows' then
            matcher:setOption 'ignoreCase'
        end
        log.debug('getLibraryMatchers', path, nPath)
        m.libraryMatchers[#m.libraryMatchers+1] = {
            path    = nPath,
            matcher = matcher
        }
    end

    m.libraryVersion = config.version
    return m.libraryMatchers
end

--- 文件是否被忽略
function m.isIgnored(uri)
    local path = furi.decode(uri)
    local ignore = m.getNativeMatcher()
    return ignore(path)
end

local function interfaceFactory(root)
    return {
        type = function (path)
            if fs.is_directory(fs.path(root .. '/' .. path)) then
                return 'directory'
            else
                return 'file'
            end
        end,
        list = function (path)
            local fullPath = fs.path(root .. '/' .. path)
            if not fs.exists(fullPath) then
                return nil
            end
            local paths = {}
            for fullpath in fullPath:list_directory() do
                paths[#paths+1] = fullpath:string()
            end
            return paths
        end
    }
end

local function loadFileFactory(root, progress, isLibrary)
    return function (path)
        local uri = furi.encode(root .. '/' .. path)
        if not files.isLua(uri) then
            return
        end
        progress.max = progress.max + 1
        pub.task('loadFile', uri, function (text)
            progress.read = progress.read + 1
            --log.info(('Preload file at: %s , size = %.3f KB'):format(uri, #text / 1000.0))
            if isLibrary then
                files.setLibraryPath(uri, root)
            end
            files.setText(uri, text)
        end)
    end
end

--- 预读工作区内所有文件
function m.awaitPreload()
    if not m.uri then
        return
    end
    local progress = {
        max  = 0,
        read = 0,
    }
    log.info('Preload start.')
    local matcherOption = {
        ignoreCase = true
    }
    local nativeInterface = interfaceFactory(m.path)
    local nativeLoader    = loadFileFactory(m.path, progress)
    local native          = m.getNativeMatcher(matcherOption, nativeInterface)
    local librarys        = m.getLibraryMatchers(matcherOption)
    native:scan(nativeLoader)
    for _, library in ipairs(librarys) do
        local libraryInterface = interfaceFactory(library.path)
        local libraryLoader    = loadFileFactory(library.path, progress, true)
        for k, v in pairs(libraryInterface) do
            library.matcher:setInterface(k, v)
        end
        library.matcher:scan(libraryLoader)
    end

    log.info(('Found %d files.'):format(progress.max))
    while true do
        log.info(('Loaded %d/%d files'):format(progress.read, progress.max))
        if progress.read >= progress.max then
            break
        end
        await.sleep(0.1)
    end

    log.info('Preload finish.')

    local diagnostic = require 'provider.diagnostic'
    diagnostic.start()
end

--- 查找符合指定file path的所有uri
---@param path string
function m.findUrisByFilePath(path)
    local results = {}
    local posts = {}
    for uri in files.eachFile() do
        local pathLen = #path
        local uriLen  = #uri
        local seg = uri:sub(uriLen - pathLen, uriLen - pathLen)
        if seg == '/' or seg == '\\' or seg == '' then
            local see = uri:sub(uriLen - pathLen + 1, uriLen)
            if files.eq(see, path) then
                results[#results+1] = uri
                posts[uri] = files.getOriginUri(uri):sub(1, uriLen - pathLen)
            end
        end
    end
    return results, posts
end

--- 查找符合指定require path的所有uri
---@param path string
---@param whole boolean
function m.findUrisByRequirePath(path)
    local results = {}
    local mark = {}
    local searchers = {}
    local input = path:gsub('%.', '/')
                      :gsub('%%', '%%%%')
    for _, luapath in ipairs(config.config.runtime.path) do
        local part = luapath:gsub('%?', input)
        local uris, posts = m.findUrisByFilePath(part)
        for _, uri in ipairs(uris) do
            if not mark[uri] then
                mark[uri] = true
                results[#results+1] = uri
                searchers[uri] = posts[uri] .. luapath
            end
        end
    end
    return results, searchers
end

function m.normalize(path)
    if platform.OS == 'Windows' then
        path = path:gsub('[/\\]+', '\\')
    else
        path = path:gsub('[/\\]+', '/')
    end
    return path:gsub('^[/\\]+', '')
end

function m.getRelativePath(uri)
    local path = furi.decode(uri)
    local _, pos = m.normalize(path):lower():find(m.path:lower(), 1, true)
    if pos then
        return m.normalize(path:sub(pos + 1))
    else
        return m.normalize(path)
    end
end

function m.reload()
    files.removeAll()
    rpath.flush()
    await.close 'preload'
    await.call(m.awaitPreload, 'preload')
end

files.watch(function (ev, uri)
    if ev == 'close' and m.isIgnored(uri) then
        files.remove(uri)
    end
end)

return m
