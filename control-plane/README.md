# Control plane app for db_join P4 app
This folder contains the control plane application for the P4 app `db_join`. It is written in golang.

## Setup
A requirement is that the Intel software development environment must be already installed.
### Compile
1. Move to this folder. e.g. `cd ~/src/db_join/control-plane`
2. Compile using make
  ```
  make build
  ```
After compiling, there should be a binary named `db-join-cp`, which you can execute without any parameters.
### Compile & Run
```
make run
```
