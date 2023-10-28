all:
	mkdir -p bin
	go build -o bin/uploader ./cmd/uploader 
	go build -o bin/receiver ./cmd/receiver 

clean:
	rm -rv ./bin
	
