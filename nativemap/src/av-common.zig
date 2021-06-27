usingnamespace @cImport({
    @cInclude("libavcodec/avcodec.h");
});

pub const AVError = error{
    FailedOpenInput,
    FailedGuessingFormat,
    FailedAvioOpen,
    FailedFindStreamInfo,
    FailedSwrContextAlloc,
    FailedFindCodec,
    FailedCodecOpen,
    FailedFrameAlloc,
    NoStreamFound,
    FailedStreamCreation,
    BadResponseError,
    FailedSwrConvert,
    FailedEncode,
    FailedDecode,
    FailedConversion,
    BadResponse,
};

pub fn initAVCodec() void {
    avcodec_register_all();
}
