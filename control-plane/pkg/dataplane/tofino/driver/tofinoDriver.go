package driver

import (
	"context"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"net"
	"strconv"
	"time"

	"github.com/thushjandan/tofino-p4-db-join/internal/dataplane/tofino/protos/bfruntime"
	"google.golang.org/grpc"
)

type TofinoDriver struct {
	isConnected      bool
	conn             *grpc.ClientConn
	client           bfruntime.BfRuntimeClient
	streamChannel    bfruntime.BfRuntime_StreamChannelClient
	ctx              context.Context
	cancel           context.CancelFunc
	clientId         uint32
	P4Tables         []Table
	NonP4Tables      []Table
	indexP4Tables    map[string]int
	indexNonP4Tables map[string]int
	portCache        map[string][]byte
}

func NewTofinoDriver() TofinoDriver {
	return TofinoDriver{
		isConnected: false,
		clientId:    uint32(rand.Intn(100)),
	}
}

func (driver *TofinoDriver) Connect(host string, port int) {
	// If a connection already exists, then stop here
	if driver.isConnected {
		return
	}
	log.Printf("Connect to Tofino %s:%d\n", host, port)

	var err error

	maxSizeOpt := grpc.MaxCallRecvMsgSize(16 * 10e6) // increase incoming grpc message size to 16MB
	driver.conn, err = grpc.Dial(fmt.Sprintf("%s:%d", host, port), grpc.WithTimeout(5*time.Second), grpc.WithDefaultCallOptions(maxSizeOpt), grpc.WithInsecure(), grpc.WithBlock())

	if err != nil {
		log.Fatalf("Could not connect to Tofino %v\n", err)
		return
	}

	log.Printf("Gen new Client with ID " + strconv.FormatUint(uint64(driver.clientId), 10))
	driver.client = bfruntime.NewBfRuntimeClient(driver.conn)

	driver.ctx, driver.cancel = context.WithCancel(context.Background())

	// Open stream channel
	driver.streamChannel, err = driver.client.StreamChannel(driver.ctx)

	reqSub := bfruntime.StreamMessageRequest_Subscribe{
		Subscribe: &bfruntime.Subscribe{
			DeviceId: 0,
			Notifications: &bfruntime.Subscribe_Notifications{
				EnablePortStatusChangeNotifications: false,
				EnableIdletimeoutNotifications:      true,
				EnableLearnNotifications:            true,
			},
		},
	}

	err = driver.streamChannel.Send(&bfruntime.StreamMessageRequest{ClientId: driver.clientId, Update: &reqSub})

	counter := 0
	for err != nil && counter < 3 {
		log.Printf("Subscribe failed: %s trying new id %s", err, fmt.Sprint(driver.clientId+1))
		counter += 1
		driver.clientId += 1
		err = driver.streamChannel.Send(&bfruntime.StreamMessageRequest{ClientId: driver.clientId, Update: &reqSub})
	}

	driver.isConnected = true

	// Bind client
	reqFPCfg := bfruntime.SetForwardingPipelineConfigRequest{
		ClientId: driver.clientId,
		DeviceId: 0,
		Action:   bfruntime.SetForwardingPipelineConfigRequest_BIND,
	}
	reqFPCfg.Config = append(reqFPCfg.Config, &bfruntime.ForwardingPipelineConfig{P4Name: "db_join"})

	var setForwardPipelineConfigResponse *bfruntime.SetForwardingPipelineConfigResponse
	setForwardPipelineConfigResponse, err = driver.client.SetForwardingPipelineConfig(driver.ctx, &reqFPCfg)

	if setForwardPipelineConfigResponse == nil || setForwardPipelineConfigResponse.GetSetForwardingPipelineConfigResponseType() != bfruntime.SetForwardingPipelineConfigResponseType_WARM_INIT_STARTED {
		log.Printf("tofino ASIC driver: Warm Init Failed : %s", err)
		driver.Disconnect()
		return
	}

	log.Printf("tofino ASIC driver: Warm INIT Started")

	// Request Runtome CFG
	reqGFPCfg := bfruntime.GetForwardingPipelineConfigRequest{
		ClientId: driver.clientId,
		DeviceId: 0,
	}
	var getForwardPipelineConfigResponse *bfruntime.GetForwardingPipelineConfigResponse
	getForwardPipelineConfigResponse, err = driver.client.GetForwardingPipelineConfig(driver.ctx, &reqGFPCfg)

	if getForwardPipelineConfigResponse == nil {
		log.Printf("Could not get ForwardingPipelineConfig : %s", err)
		driver.Disconnect()
		return
	}

	log.Printf("Connection is ready to use")
	// Parse BfrtInfo
	driver.P4Tables, err = UnmarshalBfruntimeInfoJson(getForwardPipelineConfigResponse.Config[0].BfruntimeInfo)
	if err != nil {
		log.Printf("Could not parse P4Table BfrtInfo payload. Error: %v", err)
		driver.Disconnect()
		return
	}
	// Create Hash table for faster retrieval of tables
	driver.createP4TableIndex()
	// Parse NonP4Tables BfrtInfo
	driver.NonP4Tables, err = UnmarshalBfruntimeInfoJson(getForwardPipelineConfigResponse.NonP4Config.BfruntimeInfo)
	if err != nil {
		log.Printf("Could not parse NonP4Table BfrtInfo payload. Error: %v", err)
		driver.Disconnect()
		return
	}
	// Create Hash table for faster retrieval of tables
	driver.createNonP4TableIndex()

	// Create Hash map for port cache
	driver.portCache = make(map[string][]byte)
}

func (driver *TofinoDriver) createP4TableIndex() {
	driver.indexP4Tables = make(map[string]int)
	for i := range driver.P4Tables {
		driver.indexP4Tables[driver.P4Tables[i].Name] = i
	}
}

func (driver *TofinoDriver) createNonP4TableIndex() {
	driver.indexNonP4Tables = make(map[string]int)
	for i := range driver.NonP4Tables {
		driver.indexNonP4Tables[driver.NonP4Tables[i].Name] = i
	}
}

func (driver *TofinoDriver) GetTableIdByName(tblName string) uint32 {
	tblId := uint32(0)
	// Find table name in index
	if sliceIdx, ok := driver.indexP4Tables[tblName]; ok {
		// Table name has been found in hash table
		return driver.P4Tables[sliceIdx].Id
	}

	return tblId
}

func (driver *TofinoDriver) GetKeyIdByName(tblName, keyName string) uint32 {
	keyId := uint32(0)
	// Find table name in index
	if sliceIdx, ok := driver.indexP4Tables[tblName]; ok {
		// Table name has been found in hash table
		for keyIdx := range driver.P4Tables[sliceIdx].Key {
			if driver.P4Tables[sliceIdx].Key[keyIdx].Name == keyName {
				return driver.P4Tables[sliceIdx].Key[keyIdx].Id
			}
		}
	}
	return keyId
}

func (driver *TofinoDriver) GetActionIdByName(tblName, actionName string) uint32 {
	actionId := uint32(0)
	// Find table name in index
	if sliceIdx, ok := driver.indexP4Tables[tblName]; ok {
		// Table name has been found in hash table
		for actionIdx := range driver.P4Tables[sliceIdx].ActionSpecs {
			if driver.P4Tables[sliceIdx].ActionSpecs[actionIdx].Name == actionName {
				return driver.P4Tables[sliceIdx].ActionSpecs[actionIdx].Id
			}
		}
	}
	return actionId
}

func (driver *TofinoDriver) GetDataIdByName(tblName, actionName, dataName string) uint32 {
	dataId := uint32(0)
	// Find table name in index
	if sliceIdx, ok := driver.indexP4Tables[tblName]; ok {
		// Table name has been found in hash table
		for actionIdx := range driver.P4Tables[sliceIdx].ActionSpecs {
			actionSpecObj := driver.P4Tables[sliceIdx].ActionSpecs[actionIdx]
			if actionSpecObj.Name == actionName {
				for dataIdx := range actionSpecObj.Data {
					if actionSpecObj.Data[dataIdx].Name == dataName {
						return actionSpecObj.Data[dataIdx].Id
					}
				}
			}
		}
	}
	return dataId
}

func (driver *TofinoDriver) getPortTblId() (uint32, uint32, error) {
	tblName := "$PORT_STR_INFO"
	tblId := uint32(0)
	keyId := uint32(0)
	sliceIdx, ok := driver.indexNonP4Tables[tblName]
	// Find table name in index
	if !ok {
		return tblId, keyId, errors.New("Table id of PORT_STR_INFO table has not been found in NonP4Tables")
	}

	tblId = driver.NonP4Tables[sliceIdx].Id

	for keyIdx := range driver.NonP4Tables[sliceIdx].Key {
		if driver.NonP4Tables[sliceIdx].Key[keyIdx].Name == "$PORT_NAME" {
			return tblId, driver.NonP4Tables[sliceIdx].Key[keyIdx].Id, nil
		}
	}
	return tblId, keyId, errors.New("Key id of PORT_NAME in PORT_STR_INFO table has not been found (NonP4Tables)")
}

func (driver *TofinoDriver) GetPortIdByName(portName string) ([]byte, error) {
	// Check the cache first
	if portId, ok := driver.portCache[portName]; ok {
		log.Printf("Hitting the port cache for %s", portName)
		return portId, nil
	}

	// get table id from bfrtinfo
	tblId, keyId, err := driver.getPortTblId()
	if err != nil {
		return nil, err
	}

	keyFields := []*bfruntime.KeyField{
		{
			FieldId: keyId,
			MatchType: &bfruntime.KeyField_Exact_{
				Exact: &bfruntime.KeyField_Exact{
					Value: []byte(portName),
				},
			},
		},
	}

	tblEntries := []*bfruntime.Entity{
		{
			Entity: &bfruntime.Entity_TableEntry{
				TableEntry: &bfruntime.TableEntry{
					TableId: tblId,
					Value: &bfruntime.TableEntry_Key{
						Key: &bfruntime.TableKey{
							Fields: keyFields,
						},
					},
				},
			},
		},
	}

	readReq := &bfruntime.ReadRequest{
		ClientId: driver.clientId,
		Entities: tblEntries,
		Target: &bfruntime.TargetDevice{
			DeviceId:  0,
			PipeId:    0xffff,
			PrsrId:    255,
			Direction: 255,
		},
	}
	// Send read request
	readClient, err := driver.client.Read(driver.ctx, readReq)
	if err != nil {
		return nil, err
	}
	// Read response
	resp, err := readClient.Recv()
	if err != nil {
		return nil, err
	}

	// Check if response is empty in case the item has not found
	if len(resp.Entities) == 0 {
		return nil, errors.New(fmt.Sprintf("Port %s does not exists", portName))
	}

	portId := resp.Entities[0].GetTableEntry().GetData().GetFields()[0].GetStream()
	// We need only 2 bytes
	portId = portId[len(portId)-2:]

	// Update port cache
	driver.portCache[portName] = portId

	return portId, nil
}

func (driver *TofinoDriver) AddIPv4Route(dstIpAddress net.IP, dstEtherAddress net.HardwareAddr, portName string) error {
	tblName := "pipe.SwitchIngress.ipv4_lpm"
	keyName := "hdr.ipv4.dstAddr"
	actionName := "SwitchIngress.ipv4_forward"

	byteDstIpv4Addr := dstIpAddress.To4()

	// Get PortId from the port name like 2/0
	portId, err := driver.GetPortIdByName(portName)
	if err != nil {
		return err
	}

	actionParams := map[string][]byte{"dstAddr": dstEtherAddress, "port": portId}

	tblId := driver.GetTableIdByName(tblName)
	if tblId == 0 {
		return errors.New("Table name has not been found in BfrtInfo!")
	}

	keyId := driver.GetKeyIdByName(tblName, keyName)
	if keyId == 0 {
		return errors.New(fmt.Sprintf("Key %s cannot be found in BfrtInfo", keyName))
	}

	keyFields := []*bfruntime.KeyField{
		{
			FieldId: keyId,
			MatchType: &bfruntime.KeyField_Lpm{
				Lpm: &bfruntime.KeyField_LPM{
					Value:     byteDstIpv4Addr,
					PrefixLen: 32,
				},
			},
		},
	}

	actionId := driver.GetActionIdByName(tblName, actionName)
	if actionId == 0 {
		return errors.New(fmt.Sprintf("Action %s cannot be found in BfrtInfo", actionName))
	}

	var dataFields []*bfruntime.DataField
	for actionParamName, actionParamValue := range actionParams {
		dataId := driver.GetDataIdByName(tblName, actionName, actionParamName)
		if dataId == 0 {
			return errors.New(fmt.Sprintf("ActionParam %s cannot be found in BfrtInfo", actionParamName))
		}
		dataField := &bfruntime.DataField{
			FieldId: dataId,
			Value: &bfruntime.DataField_Stream{
				Stream: actionParamValue,
			},
		}
		dataFields = append(dataFields, dataField)
	}

	tblEntry := &bfruntime.TableEntry{
		TableId: tblId,
		Value: &bfruntime.TableEntry_Key{
			Key: &bfruntime.TableKey{
				Fields: keyFields,
			},
		},
		Data: &bfruntime.TableData{
			ActionId: actionId,
			Fields:   dataFields,
		},
		IsDefaultEntry: false,
	}

	updateItems := []*bfruntime.Update{
		{
			Type: bfruntime.Update_INSERT,
			Entity: &bfruntime.Entity{
				Entity: &bfruntime.Entity_TableEntry{
					TableEntry: tblEntry,
				},
			},
		},
	}

	writeReq := bfruntime.WriteRequest{
		ClientId:  driver.clientId,
		Atomicity: bfruntime.WriteRequest_CONTINUE_ON_ERROR,
		Target: &bfruntime.TargetDevice{
			DeviceId:  0,
			PipeId:    0xffff,
			PrsrId:    255,
			Direction: 255,
		},
		Updates: updateItems,
	}

	_, err = driver.client.Write(driver.ctx, &writeReq)
	if err != nil {
		log.Printf("Inserting a new table entry failed. Error: %v", err)
		return err
	}
	log.Printf("A new ipv4 route has been added.")

	return nil
}

func (driver *TofinoDriver) Disconnect() {
	if driver.isConnected {
		log.Printf("Disconnecting from %s", driver.conn.Target())
		driver.client = nil
		driver.conn.Close()
		driver.cancel()
		driver.ctx.Done()
		driver.isConnected = false
	}
}
