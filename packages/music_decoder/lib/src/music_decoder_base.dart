import 'dart:io';

import 'ncm/ncm_decoder.dart';
import 'qmc/qmc_decoder.dart';

class MusicDecoder {
  final NcmDecoder _ncm = NcmDecoder();
  final QmcDecoder _qmc = QmcDecoder();

  Future<DecodeResult> decodeNcm(
    File input, {
    File? output,
    bool writeTags = true,
  }) {
    return _ncm.decodeFile(input, output: output, writeTags: writeTags);
  }

  Future<QmcDecodeResult> decodeQmc(
    File input, {
    File? output,
  }) {
    return _qmc.decodeFile(input, output: output);
  }
}
