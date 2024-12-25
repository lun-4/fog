all:
	mkdir -p bin
	cd ./agents/file && go build && mv ./file ../../bin/fog-agent-file

clean:
	rm -rv ./bin
	
