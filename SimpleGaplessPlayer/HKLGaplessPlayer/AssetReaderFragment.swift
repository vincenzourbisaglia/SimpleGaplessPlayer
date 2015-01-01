//
//  AssetReaderFragment.swift
//  SimpleGaplessPlayer
//
//  Created by Hirohito Kato on 2014/12/22.
//  Copyright (c) 2014年 Hirohito Kato. All rights reserved.
//

import Foundation
import AVFoundation

/**
アセットリーダーと元アセットとを管理する型。時間も管理することで、60fps以下の
ムービーでも滞りなく再生できるようにする
*/
internal class AssetReaderFragment: NSObject {
    let asset: AVAsset
    let reader: AVAssetReader!
    let rate: Float
    var frameInterval: CMTime = kCMTimeIndefinite

    init!(asset:AVAsset, rate:Float=1.0, startTime:CMTime=kCMTimeZero, var endTime:CMTime=kCMTimePositiveInfinity) {
        self.asset = asset
        self.rate = rate

        super.init()

        // リーダーとなるコンポジションを作成する
        if let result = _buildComposition(asset, rate:rate, startTime:startTime, endTime:endTime) {
            /*
            (reader, frameInterval) = result で記述すると、以下のコンパイルエラー：
            "Cannot express tuple conversion '(AVAssetReader, CMTime)' to '(AVAssetReader!, CMTime)'"
            が出てしまうため、分解して代入するようにした
            */
            (reader, frameInterval) = (result.0, result.1)
        }

        if reader == nil || frameInterval == kCMTimeIndefinite {
            NSLog("Failed to build a composition for asset.")
            return nil
        }

        // 読み込み開始
        if self.reader.startReading() == false {
            NSLog("Failed to start a reader:\(self.reader)\n error:\(self.reader.error)")
            return nil
        }
    }

    /**
    内包しているAVAssetReaderのstatusプロパティの値(AVAssetReaderStatus)を返す。
    */
    var status: AVAssetReaderStatus {
        return reader.status
    }

    /**
    内包しているAVAssetReaderの、アウトプット群の先頭にあるオブジェクト
    (AVAssetReaderOutput)を返す。
    */
    var output: AVAssetReaderOutput! {
        return reader.outputs.first as? AVAssetReaderOutput
    }

    // MARK: Private variables & methods
    /**
    アセットの指定範囲をフレーム単位で取り出すためのリーダーを作成する。
    具体的には再生時間帯を限定したコンポジションを作成し、そのフレームを取り出すための
    アウトプットを作成している

    :param: asset     読み出し元となるアセット
    :param: startTime アセットの読み出し開始位置（デフォルト：先頭）
    :param: endTime   アセットの読み出し終了位置（デフォルト：末尾）

    :returns: アセットリーダー
    */
    private func _buildComposition(asset:AVAsset, rate:Float,
        startTime:CMTime=kCMTimeZero, var endTime:CMTime=kCMTimePositiveInfinity)
        -> (AVAssetReader, CMTime)!
    {
        var error: NSError? = nil

        let videoTrack = asset.tracksWithMediaType(AVMediaTypeVideo)[0] as AVAssetTrack

        // 引数で指定した再生範囲を「いつから何秒間」の形式に変換
        if endTime > videoTrack.timeRange.duration {
            endTime = videoTrack.timeRange.duration
        }
        let duration = endTime - startTime
        let timeRange = CMTimeRangeMake(startTime, duration)

        /* 作成するコンポジションとリーダーの構造
        *
        * [AVAssetReaderVideoCompositionOutput]: ビデオフレーム取り出し口
        * │└ [AVAssetReader] ↑[videoTracks] : コンポジション上のvideoTrackを読み出し元に指定
        * │    └ [AVMutableComposition]      : 再生時間帯の指定
        * │        └ [videoTrack in AVAsset] : ソースに使うビデオトラック
        * └ [AVVideoComposition]              : フレームレート指定
        */

        // アセットのビデオトラックを配置するためのコンポジションを作成
        let composition = AVMutableComposition()
        let compoVideoTrack = composition.addMutableTrackWithMediaType(AVMediaTypeVideo,
            preferredTrackID: Int32(kCMPersistentTrackID_Invalid))

        // アセットのうち指定範囲をコンポジションのトラック上に配置する。
        compoVideoTrack.insertTimeRange(timeRange, ofTrack: videoTrack, atTime: kCMTimeZero, error: &error)
        if error != nil {
            NSLog("Failed to insert a video track to composition:\(error)")
            return nil
        }

        // フレームレート指定のためにビデオコンポジションを作成・利用(Max.60fps)
        let videoComposition = AVMutableVideoComposition(propertiesOfAsset: asset)
        let referenceRate = CMTime(value:1, Int(Float(kFrameRate) / rate))
        videoComposition.frameDuration = max(videoTrack.minFrameDuration, referenceRate)
        let frameDuration = videoComposition.frameDuration * (1.0/rate)

        // 60fps以下の場合、60fpsで出力出来るようスケールしたいが、scaleTimeRange()は
        // frameDuration以下のfpsのときには、読み出そうとしてもエラーになってしまう模様。
        // → DisplayLinkの複数回の呼び出しで同じ画像を返せるよう、ロジックを変更する
        //        let stretchRate = max(CMTimeGetSeconds(videoTrack.minFrameDuration), (1.0/60)) * 60.0
        //        println("stretchRate:\(timeRange) (\(timeRange.duration)-> \(timeRange.duration*stretchRate))")
        //        composition.scaleTimeRange(timeRange, toDuration:timeRange.duration*0.5)

        // アセットリーダーに接続するアウトプット(出力口)として、
        // ビデオコンポジションを指定できるAVAssetReaderVideoCompositionOutputを作成
        // 注意点：
        // - このビデオトラックにはコンポジション上のビデオトラックを指定すること
        // - IOSurfaceで作成しなくても再生できるが、念のため付けておく
        let compoVideoTracks = composition.tracksWithMediaType(AVMediaTypeVideo)
        var output = AVAssetReaderVideoCompositionOutput(videoTracks: compoVideoTracks,
            videoSettings: [kCVPixelBufferPixelFormatTypeKey : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey : [:]])
        output.videoComposition = videoComposition

        // サンプルバッファを取り出すときにデータをコピーしない（負荷軽減）
        output.alwaysCopiesSampleData = false

        // コンポジションからアセットリーダーを作成し、アウトプットを接続
        if let reader = AVAssetReader(asset: composition, error: &error) {
            if reader.canAddOutput(output) {
                reader.addOutput(output)
            }
            return (reader, frameDuration)
        } else {
            NSLog("Failed to instantiate a reader for a composition:\(error)")
        }
        
        return nil
    }
}
