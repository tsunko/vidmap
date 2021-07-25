pub usingnamespace @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavformat/avformat.h");
    @cInclude("libavutil/imgutils.h");
    @cInclude("libswscale/swscale.h");
    @cInclude("libswresample/swresample.h");
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
