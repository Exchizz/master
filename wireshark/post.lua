-- trivial postdissector example
-- declare some Fields to be read
rtp_payload = Field.new("rtp.payload")

-- declare our (pseudo) protocol
trivial_proto = Proto("trivial","Trivial Postdissector")

-- create the fields for our "protocol"
conv_F = ProtoField.string("trivial.conv","Conversation","A Conversation")
data_F = ProtoField.string("trivial.conv","Conversation","A Conversation")

-- create a function to "postdissect" each frame
function trivial_proto.dissector(buffer,pinfo,tree)
    local rtp_payload = rtp_payload()
    local subtree = tree:add(trivial_proto,"Payload parser")
    local counter = Struct.fromhex(tostring(rtp_payload():subset(0,4)))
    subtree:add(conv_F,"Counter: " .. counter)
    subtree:add(data_F,"Data: " .. tostring(rtp_payload))
end
-- register our protocol as a postdissector
register_postdissector(trivial_proto)
