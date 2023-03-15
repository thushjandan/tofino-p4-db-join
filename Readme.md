# Intel Tofino P4 application for table join between two relations
This P4 application is a toy example, which implements a table join between two relations within the dataplane. This P4 application has been build for the Intel Tofino Native architecture.

## Overview
Let's assume we have two tables/relations, called `R` & `S`, and they have each three (unsigned) integer attributes.

First we pump the table `R` with random numbers to the switch. The switch will store these tuples in a hash table using `extern Register`.

Then we pump the table `S` with random numbers to the switch. The switch will recognized the table `S` and will do an INNER JOIN with table `R`.

### Example
**Relation R**
| entityId | secondAttr | thirdAttr |
|----------|------------|-----------|
| 123      | 32         | 214       |
| 45       | 234        | 56        |
| 6        | 456        | 852       |
| 789      | 685        | 145       |

**Relation S**
| entityId | secondAttr | thirdAttr |
|----------|------------|-----------|
| 209      | 642        | 595       |
| 45       | 53         | 842       |
| 321      | 67         | 1         |
| 789      | 74         | 315       |

**Result**
| entityId | secondAttr | thirdAttr | forthAttr | fifthAttr |
|----------|------------|-----------|-----------|-----------|
| 45       | 234        | 56        | 53        | 842       |
| 789      | 685        | 145       | 74        | 315       |


## Design
After the IPv4 header, the [MYP4DB_Relation](#relational-header-myp4db_relation) header will be appended, which contains the metadata for a relation. IPv4 protocol number 0xFA (250) is used to indicate that header.
An additional header of type [DBEntry](#request-tuple-dbentry) will follow, which contains a single tuple.

The switch will process the tuple from the header. If the switch decides to store the relation in case of an empty hash table, it will drop the whole packet after processing.

In case the requested relation is a different from the relation stored on the switch, a INNER JOIN operation is assumed on the switch and a header of type [DBReplyEntry](#reply-tuple-joined-tuple), containing the joined tuple, is generated.

### Relational Header (MYP4DB_Relation)
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|   relationId  |replyJoinedRel.|
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
Total 2 bytes (16-bits)
* relationId (8-bit): the name of the relation represented as an unsigned integer. 
* replyJoinedRelation (8-bit): the name of the joined relation represented as an unsigned integer. The default is empty (0) and will only be used within a reply packet.

### Request Tuple (DBEntry)
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           entryId                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           secondAttr                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           thirdAttr                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
Total 12 bytes (96 bits)
* entryId (32-bit): primary key represented as an unsigned integer.
* secondAttr (32-bit): Second attribute of the tuple represented as an unsigned integer.
* thirdAttr (32-bit): Third attribute of the tuple represented as an unsigned integer.

### Reply Tuple (Joined tuple)
```
 0                   1                   2                   3
 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           entryId                             |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           secondAttr                          |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           thirdAttr                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           forthAttr                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
|                           fifthAttr                           |
+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```
Total 20 bytes (160 bits)
* entryId (32-bit): primary key represented as an unsigned integer.
* secondAttr (32-bit): Second attribute of the tuple represented as an unsigned integer.
* thirdAttr (32-bit): Third attribute of the tuple represented as an unsigned integer.
* forthAttr (32-bit): Forth attribute of the tuple represented as an unsigned integer.
* fifthAttr (32-bit): Fifth attribute of the tuple represented as an unsigned integer.

## Example
* Start the switch simulator running our P4 code.
* In a new terminal, execute `sniff_pkts.py` script
```
sudo python3 bfrt_python/sniff_pkts.py
```
* In a new terminal, execute `send_pkts.py` script to send requests
```
sudo python3 bfrt_python/send_pkts.py
```

### Example output
20 packets will be sent from h1 (veth1). All the tuples in the first 10 packets will be stored in the hash table of the switch. The last 10 requests will trigger a INNER JOIN on the switch, due to a different relationId, and h2 (veth17) will receive all the joined records.

Long story short, all the joined tuples (INNER JOIN) can be found in the DBReplyEntry header => [see here](#retrieved-packets-on-h2).
#### 2 samples sent by h1, which will be stored on the switch
```
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 52
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = 250
     chksum    = 0x62cd
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 1
        replyJoinedrelationId= 0
###[ DBEntry ]### 
           entryId   = 460
           secondAttr= 333
           thirdAttr = 524
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'

###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 52
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = 250
     chksum    = 0x62cd
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 1
        replyJoinedrelationId= 0
###[ DBEntry ]### 
           entryId   = 502
           secondAttr= 840
           thirdAttr = 421
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'
```
#### 2 samples sent by h1, which will trigger a JOIN on the switch
As the switch holds currently tuples from the relation R with id `1`, we send tuples from relation S with id `2` now
```
###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 52
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = 250
     chksum    = 0x62cd
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 0
###[ DBEntry ]### 
           entryId   = 460
           secondAttr= 884
           thirdAttr = 547
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'

###[ Ethernet ]### 
  dst       = ff:ff:ff:ff:ff:ff
  src       = 08:00:00:00:01:11
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 52
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 64
     proto     = 250
     chksum    = 0x62cd
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 0
###[ DBEntry ]### 
           entryId   = 502
           secondAttr= 48
           thirdAttr = 244
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'
```
#### Retrieved packets on h2
```sniffing on eth0
###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 60
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = 250
     chksum    = 0x63c5
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 1
###[ DBReplyEntry ]### 
           entryId   = 502
           secondAttr= 48
           thirdAttr = 244
           forthAttr = 840
           fifthAttr = 421
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'

###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 60
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = 250
     chksum    = 0x63c5
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 1
###[ DBReplyEntry ]### 
           entryId   = 460
           secondAttr= 884
           thirdAttr = 547
           forthAttr = 333
           fifthAttr = 524
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'

###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 60
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = 250
     chksum    = 0x63c5
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 1
###[ DBReplyEntry ]### 
           entryId   = 299
           secondAttr= 35
           thirdAttr = 131
           forthAttr = 699
           fifthAttr = 306
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'

###[ Ethernet ]### 
  dst       = 08:00:00:00:02:22
  src       = ff:ff:ff:ff:ff:ff
  type      = IPv4
###[ IP ]### 
     version   = 4
     ihl       = 5
     tos       = 0x0
     len       = 60
     id        = 1
     flags     = 
     frag      = 0
     ttl       = 63
     proto     = 250
     chksum    = 0x63c5
     src       = 10.0.1.1
     dst       = 10.0.2.2
     \options   \
###[ MYP4DB_Relation ]### 
        relationId= 2
        replyJoinedrelationId= 1
###[ DBReplyEntry ]### 
           entryId   = 588
           secondAttr= 334
           thirdAttr = 742
           forthAttr = 707
           fifthAttr = 922
###[ UDP ]### 
              sport     = 1234
              dport     = 4321
              len       = 18
              chksum    = 0x0
###[ Raw ]### 
                 load      = 'P4 is cool'
```
