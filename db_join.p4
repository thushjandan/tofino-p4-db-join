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
typedef bit<10> hashedKey_t;

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
    bit<8>  joinedRelationId;
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

parser SwitchIngressParser(packet_in packet,
                out headers hdr,
                out metadata meta,
                out ingress_intrinsic_metadata_t ig_intr_md) {

    state start {
        /* TNA-specific Code for simple cases */
        // tofino2_specs.p4
        packet.extract(ig_intr_md);
        packet.advance(PORT_METADATA_SIZE);

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

parser SwitchEgressParser(packet_in packet,
                out headers hdr,
                out metadata meta,
                out egress_intrinsic_metadata_t eg_intr_md) {

    state start {
        /* TNA-specific Code for simple cases */
        packet.extract(eg_intr_md);

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

    /*  Parse the db_reply_tuple header */
    state parse_entries {
        packet.extract(hdr.db_reply_tuple);
        transition accept;
    }
}

/*************************************************************************
**************  I N G R E S S   P R O C E S S I N G   *******************
*************************************************************************/
/*
* Precalculates the hash value of the entryId and returns it.
*/
control calc_entryId_hash(inout headers hdr,
                  inout metadata meta,
                  out hashedKey_t hashResult) {
    
    // Hash function for hashing key in the hash table
    Hash<hashedKey_t>(HashAlgorithm_t.CRC16) crc16Hashfct;

    apply {
        hashResult = crc16Hashfct.get({ hdr.db_tuple.entryId });
    }
}

control SwitchIngress(inout headers hdr,
                  inout metadata meta,
                  /* Intrinsic */
                  in ingress_intrinsic_metadata_t                     ig_intr_md, 
                  in ingress_intrinsic_metadata_from_parser_t         ig_prsr_md,
                  inout ingress_intrinsic_metadata_for_deparser_t     ig_dprsr_md,
                  inout ingress_intrinsic_metadata_for_tm_t           ig_tm_md) {
    
    // computed hash value of entryId will be populated.
    hashedKey_t entryIdHash;

    // Initialize hash table with value 0
    Register<db_values_t, hashedKey_t>(NB_CELLS, {0, 0}) database;

    // Updates the database with the values from PHV
    RegisterAction<db_values_t, hashedKey_t, void>(database) db_update_action = {
        void apply(inout db_values_t value) {
            value.secondAttr = hdr.db_tuple.secondAttr;
            value.thirdAttr = hdr.db_tuple.thirdAttr;
        }
    };

    // Returns the tuple from the database
    RegisterAction2<db_values_t, hashedKey_t, db_attribute_t, db_attribute_t>(database) db_read_action = {
        void apply(inout db_values_t value, out db_attribute_t secondAttr, out db_attribute_t thirdAttr) {
            secondAttr = value.secondAttr;
            thirdAttr = value.thirdAttr;
        }
    };

    action drop() {
        ig_dprsr_md.drop_ctl = 0x1; // drop packet.
    }

    action ipv4_forward(macAddr_t dstAddr, PortId_t port) {
        ig_tm_md.ucast_egress_port = port;
        hdr.ethernet.srcAddr = hdr.ethernet.dstAddr;
        hdr.ethernet.dstAddr = dstAddr;
        hdr.ipv4.ttl = hdr.ipv4.ttl - 1;
    }

    /* IPv4 routing */
    table ipv4_lpm {
        key = {
            hdr.ipv4.dstAddr: lpm;
        }
        actions = {
            ipv4_forward;
            drop;
            NoAction;
        }
        size = 16;
        default_action = drop();
    }


    // Insert tuple in the hash table
    action insert_entry() {
        // Add entry to the hash table. Values are directly taken from PHV
        // hash of entryId is the key, which has been computed in a previous stage.
        db_update_action.execute(entryIdHash);
        // Drop packet after processing
        drop();
    }

    // INNER JOIN Operation
    action read_entry(bit<8> storedRelationId) {
        db_attribute_t secondAttr = 0;
        db_attribute_t thirdAttr = 0;

        // Read entry from hash table using register action. Values are loaded into secondAttr and thirdAttr variable!
        secondAttr = db_read_action.execute(entryIdHash, thirdAttr);

        // Add a new entry in reply header stack
        hdr.db_reply_tuple.setValid();
        hdr.db_reply_tuple.entryId = hdr.db_tuple.entryId;
        hdr.db_reply_tuple.secondAttr = hdr.db_tuple.secondAttr;
        hdr.db_reply_tuple.thirdAttr = hdr.db_tuple.thirdAttr;
        hdr.db_reply_tuple.forthAttr = secondAttr;
        hdr.db_reply_tuple.fifthAttr = thirdAttr;

        // Update joinedRelationId
        hdr.db_relation.joinedRelationId = storedRelationId;

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
        size = 16;

        // Prepopulate table
        const entries = {
            (1) : insert_entry();
            (2) : read_entry(1);
        }
    }

    // If reply tuple contains zero values, then drop it.
    table db_drop_reply {
        key = {
            hdr.db_reply_tuple.forthAttr: exact;
            hdr.db_reply_tuple.fifthAttr: exact;
        }

        actions = {
            drop;
            NoAction;
        }
        // Forward packet if reply tuple contains non-zero values
        default_action = NoAction();
        size = 1;
        // Drop packets, if forth and fifth values are zero.
        const entries = {
            (0, 0)  : drop();
        }
    }

    apply {
        // Run IPv4 routing logic.
        ipv4_lpm.apply();

        // Run processing for db_join only if db_relation header is present
        if (hdr.db_relation.isValid()) {
            // Precalculate hash
            calc_entryId_hash.apply(hdr, meta, entryIdHash);
            // Apply DB join
            db_join.apply();
            if (hdr.db_reply_tuple.isValid()) {
                // Drop the packet, if primary key has not been found in the hash table
                db_drop_reply.apply();
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
        packet.emit(hdr.db_relation);
        packet.emit(hdr.db_reply_tuple);
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
