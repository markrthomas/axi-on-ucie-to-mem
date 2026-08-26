"""Shared AoU flit -> string decoder for the cocotb/pyuvm DV environment.

This is the Python mirror of ``dv/common/aou_flit_log.svh`` (SystemVerilog) and
``dv/common/aou_flit_log.h`` (SystemC): the same §4.3 protocol-header byte map
and the same §5.8 message field offsets, rendered in the SAME line format, so a
flit reads identically in every environment's log.

Nothing here touches the DUT: a caller hands in the integer value of a
``PLP_BITS``-wide flit that the design already produced.  It is therefore purely
observational and cannot change VERBOSE=0 behaviour.

Bit convention (identical to rtl/aou_pkg.sv): a flit is a PLP_BITS-wide vector;
the bit at *transmission offset* ``g`` (g = 0 is the first bit on the wire) is
``flit[PLP_BITS-1-g]``.  Messages are packed MSB-first and left-justified in an
MSG_MAX_BITS container, so a field at transmission offset ``off`` of width ``w``
is ``msg[MSG_MAX_BITS-1-off -: w]``.
"""

# --- §4.2 flit / PLP geometry ------------------------------------------------
GRAN_BITS = 40
NUM_GRAN = 48
PLP_PAYLOAD_BITS = GRAN_BITS * NUM_GRAN          # 1920
PLP_HDR_BITS = 80
PLP_BITS = PLP_HDR_BITS + PLP_PAYLOAD_BITS       # 2000
FDID_W = 2
CREDIT_W = 16

MSG_MAX_BITS = 1200
MSG_MAX_GRAN = 30

# --- Table 1 MSGTYPE ---------------------------------------------------------
MT_MISC = 0x0
MT_WRITEREQ = 0x1
MT_READREQ = 0x2
MT_WRITEDATA = 0x3
MT_READDATA = 0x4
MT_WRITERESP = 0x5
MT_WRITEDATAFULL = 0x6

MSGTYPE_NAME = {
    MT_MISC: "Misc",
    MT_WRITEREQ: "WriteReq",
    MT_READREQ: "ReadReq",
    MT_WRITEDATA: "WriteData",
    MT_READDATA: "ReadData",
    MT_WRITERESP: "WriteResp",
    MT_WRITEDATAFULL: "WriteDataFull",
}

# granule counts (§5.3-5.5, Tables 14/18/25)
GRAN_OF = {
    MT_WRITEREQ: 3,
    MT_READREQ: 3,
    MT_WRITEDATA: 8,
    MT_READDATA: 8,
    MT_WRITERESP: 1,
}
MISC_GRAN = 1
ACTIVATEREQ_GRAN = 4
CRDTGRANT_GRAN = 2

# --- §5.6 Misc ---------------------------------------------------------------
MISCOP_ACTIVATION = 0b010
MISCOP_CRDTGRANT = 0b100
ACTOP_NAME = {
    0b0000: "ActivateReq",
    0b0001: "ActivateAck",
    0b0010: "DeactivateReq",
    0b0011: "DeactivateAck",
}

BURST_NAME = {0: "FIXED", 1: "INCR", 2: "WRAP", 3: "RSVD"}

# Table 17: credit bucket code -> granted credits.
CRED_DECODE = (0, 1, 4, 8, 16, 32, 64, 128)

# Table 18 CrdtGrant per-plane slot offsets.
CG_WREQ_G0 = 7
CG_RREQ_G0 = 19
CG_WDATA_G0 = 31
CG_RDATA_G0 = 43
CG_WRESP_G0 = 55


def msgstart_g(i):
    """Transmission-order bit index of MsgStart[i] within the §4.3 header."""
    if i <= 11:
        return i + 4
    if i <= 23:
        return i + 8
    if i <= 35:
        return i + 28
    return i + 32


def _hdr_bit(flit, g):
    return (flit >> (PLP_BITS - 1 - g)) & 1


def flit_fdid(flit):
    return sum(_hdr_bit(flit, j) << j for j in range(FDID_W))


def flit_credit(flit):
    return sum(_hdr_bit(flit, 32 + j) << j for j in range(CREDIT_W))


def flit_msgstart(flit):
    return sum(_hdr_bit(flit, msgstart_g(i)) << i for i in range(NUM_GRAN))


def flit_payload(flit):
    return flit & ((1 << PLP_PAYLOAD_BITS) - 1)


def payload_get(payload, g, gran):
    """The `gran`-granule message starting at granule `g`, left-justified."""
    nbits = gran * GRAN_BITS
    shift = PLP_PAYLOAD_BITS - g * GRAN_BITS - nbits
    return ((payload >> shift) & ((1 << nbits) - 1)) << (MSG_MAX_BITS - nbits)


def _fld(msg, off, width):
    """msg[MSG_MAX_BITS-1-off -: width] — a field at transmission offset `off`."""
    return (msg >> (MSG_MAX_BITS - off - width)) & ((1 << width) - 1)


def get_msgtype(msg):
    return _fld(msg, 0, 4)


def msg_gran(msg):
    """Granule count of a decoded message (Misc is sized by its MISCOP)."""
    mt = get_msgtype(msg)
    if mt == MT_MISC:
        op = _fld(msg, 4, 3)
        if op == MISCOP_CRDTGRANT:
            return CRDTGRANT_GRAN
        if op == MISCOP_ACTIVATION and _fld(msg, 7, 4) == 0:
            return ACTIVATEREQ_GRAN
        return MISC_GRAN
    return GRAN_OF.get(mt, 1)


def credit_str(c):
    """§6 MsgCredit word (Table 16/17): raw value plus the decoded grants."""
    return (
        "0x%04x(rp=%d wreq=%d rreq=%d wdata=%d rdata=%d wresp=%d)"
        % (
            c,
            (c >> 14) & 0x3,
            CRED_DECODE[c & 0x7],
            CRED_DECODE[(c >> 3) & 0x7],
            CRED_DECODE[(c >> 6) & 0x7],
            CRED_DECODE[(c >> 9) & 0x7],
            CRED_DECODE[(c >> 12) & 0x3],
        )
    )


def msg_str(msg, rp):
    """Per-type field rendering; `rp` is the flit's FDId (the resource plane)."""
    mt = get_msgtype(msg)
    if mt in (MT_WRITEREQ, MT_READREQ):
        flex = _fld(msg, 8, 16)
        return "id=%d addr=0x%016x len=%d size=%d burst=%s flex=0x%04x" % (
            _fld(msg, 24, 10), _fld(msg, 56, 64), _fld(msg, 40, 8),
            _fld(msg, 34, 3), BURST_NAME[flex & 0x3], flex)
    if mt == MT_WRITEDATA:
        return "dlen=%d data=0x%064x strb=0x%08x flex=0x%04x" % (
            _fld(msg, 6, 2), _fld(msg, 24, 256), _fld(msg, 280, 32),
            _fld(msg, 8, 16))
    if mt == MT_READDATA:
        return "id=%d resp=%d last=%d dlen=%d data=0x%064x flex=0x%04x" % (
            _fld(msg, 24, 10), _fld(msg, 34, 2), _fld(msg, 36, 1),
            _fld(msg, 6, 2), _fld(msg, 40, 256), _fld(msg, 8, 16))
    if mt == MT_WRITERESP:
        return "id=%d resp=%d flex=0x%04x" % (
            _fld(msg, 24, 10), _fld(msg, 34, 2), _fld(msg, 8, 16))
    if mt == MT_MISC:
        op = _fld(msg, 4, 3)
        if op == MISCOP_CRDTGRANT:
            return (
                "op=CrdtGrant rp%d(wreq=%d rreq=%d wdata=%d rdata=%d wresp=%d)"
                % (
                    rp,
                    CRED_DECODE[_fld(msg, CG_WREQ_G0 + 3 * rp, 3)],
                    CRED_DECODE[_fld(msg, CG_RREQ_G0 + 3 * rp, 3)],
                    CRED_DECODE[_fld(msg, CG_WDATA_G0 + 3 * rp, 3)],
                    CRED_DECODE[_fld(msg, CG_RDATA_G0 + 3 * rp, 3)],
                    CRED_DECODE[_fld(msg, CG_WRESP_G0 + 2 * rp, 2)],
                )
            )
        if op == MISCOP_ACTIVATION:
            return "op=Activation aop=%s" % ACTOP_NAME.get(_fld(msg, 7, 4),
                                                           "Unknown")
        return "op=0x%x" % op
    return ""


def decode_flit(flit):
    """Render one PLP as one string per message it STARTS (§4.3 MsgStart)."""
    ms = flit_msgstart(flit)
    payload = flit_payload(flit)
    fdid = flit_fdid(flit)
    crd = credit_str(flit_credit(flit))
    out = []
    for g in range(NUM_GRAN):
        if not (ms >> g) & 1:
            continue
        gm = min(NUM_GRAN - g, MSG_MAX_GRAN)
        msg = payload_get(payload, g, gm)
        mt = get_msgtype(msg)
        out.append(
            "fdid=%d crd=%s ms=0x%012x g=%d %s gran=%d %s"
            % (fdid, crd, ms, g, MSGTYPE_NAME.get(mt, "Unknown"),
               msg_gran(msg), msg_str(msg, fdid))
        )
    return out
