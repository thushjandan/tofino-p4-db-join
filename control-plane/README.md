
# Setup

### Compile bfruntime files
```
protoc --go-grpc_opt=Mbfruntime.proto=bfruntime/ \
--go_opt=Mbfruntime.proto=bfruntime/ \
--go_out=./internal/dataplane/tofino/protos \
--go-grpc_out=./internal/dataplane/tofino/protos \
--proto_path=/home/dev/bf-sde-9.9.0/install/share/bf_rt_shared/proto/ \
--proto_path=/home/dev/bf-sde-9.9.0/pkgsrc/bf-drivers/third-party/ \
/home/dev/bf-sde-9.9.0/install/share/bf_rt_shared/proto/bfruntime.proto
```