--- Environment configuration
-- @module environment
-- This module is providing a configuration to APIcast before and during its initialization.
-- You can load several configuration files.
-- Fields from the ones added later override fields from the previous configurations.
local pl_path = require('pl.path')
local resty_env = require('resty.env')
local linked_list = require('apicast.linked_list')
local util = require('apicast.util')
local setmetatable = setmetatable
local loadfile = loadfile
local pcall = pcall
local require = require
local assert = assert
local error = error
local print = print
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local insert = table.insert
local concat = table.concat
local re = require('ngx.re')

local function parse_nameservers()
    local resolver = require('resty.resolver')
    local nameservers = {}

    for _,nameserver in ipairs(resolver.init_nameservers()) do
        -- resty.resolver returns nameservers as tables with __tostring metamethod
        -- unfortunately those objects can't be joined with table.concat
        -- and have to be converted to strings first
        insert(nameservers, tostring(nameserver))
    end

    -- return the table only if there are some nameservers
    -- because it is way easier to check in liquid and `resolver` directive
    -- has to contain at least one server, so we can skip it when there are none
    if #nameservers > 0 then
        return nameservers
    end
end

local function cpus()
    -- TODO: support /sys/fs/cgroup/cpuset/cpuset.cpus
    -- see https://github.com/sclorg/rhscl-dockerfiles/blob/ff912d8764af9a41096e63064bbc325395afa608/rhel7.sti-base/bin/cgroup-limits#L55-L75
    local nproc = util.system('nproc')
    return tonumber(nproc)
end


local _M = {}
---
-- @field default_environment Default environment name.
-- @table self
_M.default_environment = 'production'

--- Default configuration.
-- @tfield ?string ca_bundle path to CA store file
-- @tfield ?string proxy_ssl_certificate path to SSL certificate
-- @tfield ?string proxy_ssl_certificate_key path to SSL certificate key
-- @tfield ?policy_chain policy_chain @{policy_chain} instance
-- @tfield ?{string,...} nameservers list of nameservers
-- @tfield ?string package.path path to load Lua files
-- @tfield ?string package.cpath path to load libraries
-- @table environment.default_config default configuration
_M.default_config = {
    ca_bundle = resty_env.value('SSL_CERT_FILE'),
    proxy_ssl_certificate = resty_env.value('SSL_PROXY_CERTIFICATE'),
    proxy_ssl_certificate_key = resty_env.value('SSL_PROXY_CERTIFICATE_KEY'),
    policy_chain = require('apicast.policy_chain').default(),
    nameservers = parse_nameservers(),
    worker_processes = cpus() or 'auto',
    package = {
        path = package.path,
        cpath = package.cpath,
    }
}

local mt = { __index = _M }

--- Return loaded environments defined as environment variable.
-- @treturn {string,...}
function _M.loaded()
    local value = resty_env.value('APICAST_LOADED_ENVIRONMENTS')
    return re.split(value or '', [[\|]], 'jo')
end

--- Load an environment from files in ENV.
-- @treturn Environment
function _M.load()
    local env = _M.new()
    local environments = _M.loaded()

    if not environments then
        return env
    end

    for i=1,#environments do
        assert(env:add(environments[i]))
    end

    return env
end

--- Initialize new environment.
-- @treturn Environment
function _M.new()
    return setmetatable({ _context = linked_list.readonly(_M.default_config), loaded = {} }, mt)
end

local function expand_environment_name(name)
    local root = resty_env.value('APICAST_DIR') or pl_path.abspath('.')
    local pwd = resty_env.value('PWD')

    local path = pl_path.abspath(name, pwd)
    local exists = pl_path.isfile(path)

    if exists then
        return nil, path
    end

    path = pl_path.join(root, 'config', ("%s.lua"):format(name))
    exists = pl_path.isfile(path)

    if exists then
        return name, path
    end
end

---------------------
--- @type Environment
-- An instance of @{environment} configuration.

--- Add an environment name or configuration file.
-- @tparam string env environment name or path to a file
function _M:add(env)
    local name, path = expand_environment_name(env)

    if self.loaded[path] then
        return true, 'already loaded'
    end

    if name and path then
        self.name = name
        print('loading ', name ,' environment configuration: ', path)
    elseif path then
        print('loading environment configuration: ', path)
    else
        return nil, 'no configuration found'
    end

    local config = loadfile(path, 't', {
        print = print, inspect = require('inspect'), context = self._context,
        tonumber = tonumber, tostring = tostring, os = { getenv = resty_env.value },
        pcall = pcall, require = require, assert = assert, error = error,
    })

    if not config then
        return nil, 'invalid config'
    end

    self.loaded[path] = true

    self._context = linked_list.readonly(config(), self._context)

    return true
end

--- Read/write context
-- @treturn table context with all loaded environments combined
function _M:context()
    return linked_list.readwrite({ }, self._context)
end

--- Store loaded environment file names into ENV.
function _M:save()
    local environments = {}

    for file,_ in pairs(self.loaded) do
        insert(environments, file)
    end

    resty_env.set('APICAST_LOADED_ENVIRONMENTS', concat(environments, '|'))
end

return _M
