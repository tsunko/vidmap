// Workaround for AV_CHANNEL_LAYOUT_MASK's union initialization issue
static inline AVChannelLayout _initAVChannelLayout(int nb, unsigned long long m) {
    AVChannelLayout l = {0};
    l.order = AV_CHANNEL_ORDER_NATIVE;
    l.nb_channels = nb;
    l.u.mask = m;
    return l;
}
#define AV_CHANNEL_LAYOUT_MASK(nb, m) _initAVChannelLayout(nb, m)

// Workaround for MKTAG using a mix of signed and unsigned integers with bitwise operations
#define MKTAG(a,b,c,d) (((unsigned)a) | ((unsigned)(b) << 8) | ((unsigned)(c) << 16) | ((unsigned)(d) << 24))