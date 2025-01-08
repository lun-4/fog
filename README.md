# fog

**f**ucking l**og**

problem statement:
> i am too insecure of running `journalctl | grep` in the production box

problem solution:
copy [whatever apenwarr smoked up and gave down to our eyes](https://apenwarr.ca/log/20190216) and make it worse

this is experimental software. no idea if this is gonna work yet

## how

get:
- elixir 1.15+ (Erlang/OTP 26+)
- go v1.23.2+
- server with storage

on the server with storage:
```sh
git clone https://github.com/lun-4/fog.git
cd fog

# build agent and cli
make

# build server component
cd server
mix deps.get
env MIX_ENV=prod mix compile
env MIX_ENV=prod mix fog.token create "my agents"
env MIX_ENV=prod mix fog.token create "myself"

env MIX_ENV=prod FOG_DATA_PATH=/lots/of/storage/fog-logs mix phx.server

# spin agent somewhere
export FOG_TOKEN=12384837597_tokenforagent
./bin/fog-agent-file -token $FOG_TOKEN -server ws://server.com:4087 -file /mylog.txt -key0 server0 -key1 service1


export FOG_TOKEN=81375982379_tokenforself

# fetch logs now
./bin/fog -server http://localhost:4087 -selector server0.service1 -since 2h

# fetch then follow logs live
./bin/fog -server http://localhost:4087 -selector server0.service1 -follow

# all key1 from key0
./bin/fog -server http://localhost:4087 -selector server0.\* -follow

# all key0 with specified key1
./bin/fog -server http://localhost:4087 -selector \*.service1 -follow
```

## architecture

- clients run on various machines
- push their logs to receivers via some api (http)
- ???????
- how does indexing work
- ????????
- `tail -f` the world
- ????????
- profit
