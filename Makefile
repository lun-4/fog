all:
	mkdir -p bin
	cd ./agents/file && go build && mv ./file ../../bin/fog-agent-file
	cd ./cli && go build && mv ./cli ../bin/fog

clean:
	rm -rv ./bin
	
