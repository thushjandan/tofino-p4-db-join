package main

import (
	"log"
	"net"

	"github.com/thushjandan/tofino-p4-db-join/pkg/dataplane/tofino/driver"
)

func main() {
	log.Println("Start control plane for db_join")
	host := "127.0.0.1"
	port := 50052
	driver := driver.NewTofinoDriver()

	err := driver.Connect(host, port)
	if err != nil {
		log.Printf("Cannot connect to Tofino. Error: %v", err)
		return
	}
	defer driver.Disconnect()
	hwAddr, err := net.ParseMAC("00:00:00:00:00:02")
	if err != nil {
		log.Printf("Invalid mac address given as param")
		return
	}

	// Add as a test an IPv4 route
	err = driver.AddIPv4Route(net.IPv4(10, 0, 3, 3), hwAddr, "2/0")
	if err != nil {
		log.Printf("Cannot add ipv4 route. Error: %v", err)
	}
	err = driver.EnableSyncOperationOnDatabase()
	if err != nil {
		log.Printf("Cannot enable sync operation. Error: %v", err)
		return
	}
	// Read entryId from register
	entryId := uint32(407)
	secondAttr, thirdAttr, err := driver.GetTupleByKeyFromDatabase(entryId)
	if err != nil {
		log.Printf("Cannot find entryId %d. Error: %v", entryId, err)
		return
	}
	log.Printf("Result for entryId %d is secondAttr %d and %d", entryId, secondAttr, thirdAttr)

}
