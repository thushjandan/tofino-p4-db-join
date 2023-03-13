/* -*- P4_16 -*- */
#include <core.p4>
/* TOFINO Native architecture */
#include <t2na.p4>

/* Max hash table cells */
#define NB_CELLS 1024

const bit<16> TYPE_IPV4 = 0x800;
const bit<8> TYPE_MYP4DB = 0xFA;

/*************************************************************************
*********************** H E A D E R S  ***********************************
*************************************************************************/

typedef bit<48> macAddr_t;
typedef bit<32> ip4Addr_t;
typedef bit<32> db_attribute_t;

header ethernet_t {
    macAddr_t dstAddr;
    macAddr_t srcAddr;
    bit<16>   etherType;
}

header ipv4_t {
    bit<4>    version;
    bit<4>    ihl;
    bit<8>    diffserv;
    bit<16>   totalLen;
    bit<16>   identification;
    bit<3>    flags;
    bit<13>   fragOffset;
    bit<8>    ttl;
    bit<8>    protocol;
    bit<16>   hdrChecksum;
    ip4Addr_t srcAddr;
    ip4Addr_t dstAddr;
}

header db_relation_t {
    bit<8>  relationId;
}

header db_tuple_t {
    db_attribute_t  entryId;
    db_attribute_t  secondAttr;
    db_attribute_t  thirdAttr;
}

header db_reply_tuple_t {
    db_attribute_t  entryId;
    db_attribute_t  secondAttr;
    db_attribute_t  thirdAttr;
    db_attribute_t  forthAttr;
    db_attribute_t  fifthAttr;
}

struct db_values_t {
    db_attribute_t secondAttr;
    db_attribute_t thirdAttr;
}

struct metadata {
    
}

struct headers {
    ethernet_t          ethernet;
    ipv4_t              ipv4;
    db_relation_t       db_relation;
    db_tuple_t          db_tuple;
    db_reply_tuple_t    db_reply_tuple;
}

/*************************************************************************
*********************** P A R S E R  ***********************************
*************************************************************************/

parser DBTupleParser(packet_in packet, out headers hdr) {

    state start {        
        transition parse_ethernet;
    }

    state parse_ethernet {
        packet.extract(hdr.ethernet);
        transition select(hdr.ethernet.etherType) {
            TYPE_IPV4: parse_ipv4;
            default: accept;
        }
    }

    state parse_ipv4 {
        packet.extract(hdr.ipv4);
        transition select(hdr.ipv4.protocol) {
            TYPE_MYP4DB     : parse_relation;
            default         : accept;
        }
    }

    /* Parse the relation header */ 
    state parse_relation {
        packet.extract(hdr.db_relation);
        transition parse_entries;
    }

    /*  Parse the db_tuple header */
    state parse_entries {
        packet.extract(hdr.db_tuple);
        transition accept;
    }

}

parser SwitchIngressParser(packet_in packet,
                out headers hdr,
                out metadata meta,
                out ingress_intrinsic_metadata_t ig_intr_md) {
    DBTupleParser() dbtuple_parser;

    state start {
        /* TNA-specific Code for simple cases */
        // tofino2_specs.p4
        packet.extract(ig_intr_md);
        packet.advance(PORT_METADATA_SIZE);

        dbtuple_parser.apply(packet, hdr);
        transition accept;
    }
}

parser SwitchEgressParser(packet_in packet,
                out headers hdr,
                out metadata meta,
                out egress_intrinsic_metadata_t eg_intr_md) {
    DBTupleParser() dbtuple_parser;

    state start {
        /* TNA-specific Code for simple cases */
        packet.extract(eg_intr_md);

        dbtuple_parser.apply(packet, hdr);
        transition accept;
    }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control SwitchIngress(inout headers hdr,
                  inout metadata meta,
                  /* Intrinsic */
                  in ingress_intrinsic_metadata_t                     ig_intr_md, 
                  in ingress_intrinsic_metadata_from_parser_t         ig_prsr_md,
                  inout ingress_intrinsic_metadata_for_deparser_t     ig_dprsr_md,
                  inout ingress_intrinsic_metadata_for_tm_t           ig_tm_md) {
    
    // Initialize hash table with value 0
    Register<db_values_t, bit<16>>(NB_CELLS, {0, 0}) database;
    RegisterAction<db_values_t, bit<16>, void>(database) db_update_action = {
        void apply(inout db_values_t value) {
            value.secondAttr = hdr.db_tuple.secondAttr;
            value.thirdAttr = hdr.db_tuple.thirdAttr;
        }
    };
    RegisterAction2<db_values_t, bit<16>, db_attribute_t, db_attribute_t>(database) db_read_action = {
        void apply(inout db_values_t value, out db_attribute_t secondAttr, out db_attribute_t thirdAttr) {
            secondAttr = value.secondAttr;
            thirdAttr = value.thirdAttr;
        }
    };

    // Hash function for hashing key in the hash table
    Hash<bit<16>>(HashAlgorithm_t.CRC16) crc16Hashfct;

    action drop() {
        ig_dprsr_md.drop_ctl = 0x1; // drop packet.
    }

    action ipv4_forward(macAddr_t dstAddr, PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 1024;
        default_action = drop();
    }

    action insert_entry() {
        // Insert tuple in the hash table
        bit<16> hashedKey = 0;
        bit<64> tmpTuple = 0;
        bit<64> tmpTuple2 = 0;
        //db_values_t tmpTuple = { hdr.db_tuple.secondAttr, hdr.db_tuple.thirdAttr };

        // Encode all the attributes into a single field.
        //tmpTuple[63:32] = hdr.db_tuple.secondAttr;
        //tmpTuple[31:0] = hdr.db_tuple.thirdAttr;
        //tmpTuple = (bit<64>) hdr.db_tuple.secondAttr << 32;
        //tmpTuple = (tmpTuple | (bit<64>)hdr.db_tuple.thirdAttr);

        // Hash the primary key (entryId)
        hashedKey = crc16Hashfct.get({ hdr.db_tuple.entryId });
        // Add entry to the hash table
        //database.write(hashedKey, tmpTuple);
        db_update_action.execute(hashedKey);
        // Drop packet after processing
        drop();
    }

    action read_entry() {
        // INNER JOIN Operation
        bit<16> hashedKey = 0;
        //bit<32> tmpTuple = 0;
        //bit<16> secondAttr = 0;
        //bit<16> thirdAttr = 0;
        db_values_t tmpTuple = {0, 0};
        db_attribute_t secondAttr = 0;
        db_attribute_t thirdAttr = 0;

        // Hash primary key (entryId)
        hashedKey = crc16Hashfct.get({ hdr.db_tuple.entryId });
        // Read entry from hash table
        //tmpTuple = database.read(hashedKey);
        secondAttr = db_read_action.execute(hashedKey, thirdAttr);
        //thirdAttr = db_read_thirdAttr.execute(hashedKey);
        // Decode the value from the register
        //secondAttr = (bit<32>)tmpTuple;
        //thirdAttr = (bit<32>)(tmpTuple >> 32);
        //thirdAttr = tmpTuple.thirdAttr;

        // Add a new entry in reply header stack
        hdr.db_reply_tuple.setValid();
        hdr.db_reply_tuple.entryId = hdr.db_tuple.entryId;
        hdr.db_reply_tuple.secondAttr = hdr.db_tuple.secondAttr;
        hdr.db_reply_tuple.thirdAttr = hdr.db_tuple.thirdAttr;
        hdr.db_reply_tuple.forthAttr = secondAttr;
        hdr.db_reply_tuple.fifthAttr = thirdAttr;

        // Increase by 8 bytes for adding two addition fields => Diff db_entry and db_reply_entry
        hdr.ipv4.totalLen = hdr.ipv4.totalLen + 8;
        
        // Remove db_tuple header
        hdr.db_tuple.setInvalid();
    }

    table db_join {
        key = {
            hdr.db_relation.relationId: exact;
        }
        actions = {
            insert_entry;
            read_entry;
        }
        //default_action = read_entry();
        size = 16;

        // Prepopulate table
        const entries = {
            (1) : insert_entry();
            (2) : read_entry();
        }
    }

    apply {
        // Run IPv4 routing logic.
        ipv4_lpm.apply();

        // Run processing for db_join only if db_relation header is present
        if (hdr.db_relation.isValid()) {
            db_join.apply();
            // If primary key has not been found in the hash table
            // Drop the packet
            //if (hdr.db_reply_tuple.isValid() && hdr.db_reply_tuple.forthAttr == 0 && hdr.db_reply_tuple.fifthAttr == 0) {
            //if (hdr.db_reply_tuple.isValid() && hdr.db_reply_tuple.forthAttr == 0) {
            if (!hdr.db_reply_tuple.isValid()) {
                drop();
            }
        }    
    }
}

/*************************************************************************
****************  E G R E S S   P R O C E S S I N G   *******************
*************************************************************************/

control SwitchEgress(inout headers hdr,
                 inout metadata meta,
                 /* Intrinsic */
                 in egress_intrinsic_metadata_t                      eg_intr_md,
                 in egress_intrinsic_metadata_from_parser_t          eg_prsr_md,
                 inout egress_intrinsic_metadata_for_deparser_t      eg_dprsr_md,
                 inout egress_intrinsic_metadata_for_output_port_t   eg_oport_md) {

    apply {

    }
}

/*************************************************************************
***********************  D E P A R S E R  *******************************
*************************************************************************/

control SwitchIngressDeparser(packet_out packet, 
                              inout headers hdr,
                              in metadata meta,
                              /* Intrinsic */
                              in ingress_intrinsic_metadata_for_deparser_t ig_dprsr_md) {

    Checksum() checksumfct;

    apply {
        //Update IPv4 checksum
        hdr.ipv4.hdrChecksum = checksumfct.update({ 
            hdr.ipv4.version,
            hdr.ipv4.ihl,
            hdr.ipv4.diffserv,
            hdr.ipv4.totalLen,
            hdr.ipv4.identification,
            hdr.ipv4.flags,
            hdr.ipv4.fragOffset,
            hdr.ipv4.ttl,
            hdr.ipv4.protocol,
            hdr.ipv4.srcAddr,
            hdr.ipv4.dstAddr 
        });

        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        packet.emit(hdr.db_relation);
        packet.emit(hdr.db_reply_tuple);
    }
}

control SwitchEgressDeparser(packet_out packet,
                             inout headers hdr,
                             in metadata meta,
                             /* Intrinsic */
                             in egress_intrinsic_metadata_for_deparser_t eg_dprsr_md) {
    apply {
        packet.emit(hdr.ethernet);
        packet.emit(hdr.ipv4);
        //TODO: need to emit db_reply_tuple!
    }
}

/*************************************************************************
***********************  S W I T C H  *******************************
*************************************************************************/

Pipeline(
    SwitchIngressParser(), 
    SwitchIngress(), 
    SwitchIngressDeparser(), 
    SwitchEgressParser(), 
    SwitchEgress(), 
    SwitchEgressDeparser()
) pipe;
Switch(pipe) main;
