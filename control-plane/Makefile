BFRT_COMPILED_PROTO=internal/dataplane/tofino/protos/bfruntime/bfruntime_grpc.pb.go

build: $(BFRT_COMPILED_PROTO)
	go build -o db-join-cp cmd/db_join-cp/main.go

run: $(BFRT_COMPILED_PROTO)
	go run cmd/db_join-cp/main.go

$(BFRT_COMPILED_PROTO):
	protoc --go-grpc_opt=Mbfruntime.proto=bfruntime/ \
	--go_opt=Mbfruntime.proto=bfruntime/ \
	--go_out=./internal/dataplane/tofino/protos \
	--go-grpc_out=./internal/dataplane/tofino/protos \
	--proto_path=/home/dev/bf-sde-9.9.0/install/share/bf_rt_shared/proto/ \
	--proto_path=/home/dev/bf-sde-9.9.0/pkgsrc/bf-drivers/third-party/ \
	/home/dev/bf-sde-9.9.0/install/share/bf_rt_shared/proto/bfruntime.proto