//
//  Created by Dimitrios Chatzieleftheriou on 10/03/2024.
//  Copyright © 2020 Decimal. All rights reserved.
//

import Foundation
import OSLog

final class RemoteMp4Restructure {
    struct RestructuredData {
        var initialData: Data
        var mdatOffset: Int
    }

    private var audioData: Data

    private var atomOffset: Int = 0
    private var atoms: [MP4Atom] = []
    private var ftyp: MP4Atom?
    private var foundMoov = false
    private var foundMdat = false

    private var task: NetworkDataStream?

    private(set) var dataOptimized: Bool = false

    private var moovAtomSize: Int = 0

    private let url: URL
    private let headers: [String: String]
    private let networking: NetworkingClient

    private let mp4Restructure: Mp4Restructure

    private var ignoreFailureDueToCancel: Bool = false

    init(url: URL, headers: [String: String] = [:], networking: NetworkingClient,
         restructure: Mp4Restructure = Mp4Restructure())
    {
        self.url = url
        self.headers = headers
        self.networking = networking
        self.audioData = Data()
        self.mp4Restructure = restructure
    }

    func clear() {
        mp4Restructure.clear()
        audioData = Data()
        task?.cancel()
        task = nil
    }

    /// Adjust the seekOffset of subtracting the moovAtomSize
    /// - Parameter offset: A byte offset
    /// - Returns: An adjusted byte offset
    func seekAdjusted(offset: Int) -> Int {
        mp4Restructure.seekAdjusted(offset: offset)
    }

    ///
    /// Gather audio and parse along the way, if moov atom is found, continue as usual
    /// if mdat is found before moov:
    ///  - Get mdat size and make a byte request Range: bytes=mdatAtomSize- for possible moov atom
    ///  - once the request is complete search for an moov atom and restructure it
    ///  - finally, make a byte request Range: bytes=mdatOffset- to get the mdat
    /// Atoms needs to be as following for the AudioFileStreamParse to work
    /// [ftyp][moov][mdat]
    ///
    func optimizeIfNeeded(completion: @escaping (Result<RestructuredData?, Error>) -> Void) {
        task = networking.stream(request: urlForPartialContent(with: url, offset: 0))
            .responseStream { [weak self] event in
                guard let self else { return }
                switch event {
                case .response:
                    break
                case let .stream(.success(response)):
                    guard let data = response.data else {
                        self.audioData = Data()
                        completion(.failure(Mp4RestructureError.unableToRestructureData))
                        return
                    }
                    self.audioData.append(data)
                    // Tempus patch: a server that never sends the atoms can't make this grow forever.
                    if self.audioData.count > Mp4Restructure.maximumMoovAtomSize {
                        self.audioData = Data()
                        self.ignoreFailureDueToCancel = true
                        self.task?.cancel()
                        self.task = nil
                        completion(.failure(Mp4RestructureError.invalidAtomSize))
                        return
                    }
                    do {
                        switch try self.mp4Restructure.checkIsOptimized(data: self.audioData) {
                        case .undetermined:
                            break // keep streaming until decision can be made
                        case .optimized:
                            self.audioData = Data()
                            self.ignoreFailureDueToCancel = true
                            self.task?.cancel()
                            self.task = nil
                            completion(.success(nil))
                        case let .needsRestructure(moovOffset):
                            guard response.response?.statusCode == 206 else {
                                Logger.error("⛔️ mp4 error: no moov before mdat and the stream is not seekable", category: .networking)
                                completion(.failure(Mp4RestructureError.nonOptimizedMp4AndServerCannotSeek))
                                return
                            }
                            // stop request, fetch moov and restructure
                            self.audioData = Data()
                            self.ignoreFailureDueToCancel = true
                            self.task?.cancel()
                            self.task = nil
                            self.fetchAndRestructureMoovAtom(offset: moovOffset) { result in
                                switch result {
                                case let .success(value):
                                    self.dataOptimized = true
                                    completion(.success(RestructuredData(initialData: value.data, mdatOffset: value.offset)))
                                case let .failure(error):
                                    completion(.failure(Mp4RestructureError.networkError(error)))
                                }
                            }
                        }
                    } catch {
                        completion(.failure(Mp4RestructureError.invalidAtomSize))
                    }
                case let .stream(.failure(error)):
                    // Ignore the error if it was caused by our intentional cancel
                    if ignoreFailureDueToCancel {
                        ignoreFailureDueToCancel = false
                        break
                    }
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                        break
                    }
                    completion(.failure(Mp4RestructureError.networkError(error)))
                case .complete:
                    break
                }
            }
        task?.resume()
    }

    /// Tempus patch: streamed with a size cap instead of buffered whole, so a server sending an
    /// endless body can't exhaust memory.
    func fetchAndRestructureMoovAtom(offset: Int, completion: @escaping (Result<(data: Data, offset: Int), Error>) -> Void) {
        var received = Data()
        var isFinished = false
        let finish = { (result: Result<(data: Data, offset: Int), Error>) in
            guard !isFinished else { return }
            isFinished = true
            completion(result)
        }
        task = networking.stream(request: urlForPartialContent(with: url, offset: offset))
            .responseStream { [weak self] event in
                guard let self else { return }
                switch event {
                case .response:
                    break
                case let .stream(.success(response)):
                    received.append(response.data ?? Data())
                    if received.count > Mp4Restructure.maximumMoovAtomSize {
                        self.ignoreFailureDueToCancel = true
                        self.task?.cancel()
                        self.task = nil
                        finish(.failure(Mp4RestructureError.invalidAtomSize))
                    }
                case let .stream(.failure(error)):
                    if self.ignoreFailureDueToCancel {
                        self.ignoreFailureDueToCancel = false
                        return
                    }
                    finish(.failure(Mp4RestructureError.networkError(error)))
                case .complete:
                    self.task = nil
                    do {
                        let (initialData, mdatOffset) = try self.mp4Restructure.restructureMoov(data: received)
                        finish(.success((initialData, mdatOffset)))
                    } catch {
                        finish(.failure(error))
                    }
                }
            }
        task?.resume()
    }

    // removed warmup range helper

    private func urlForPartialContent(with url: URL, offset: Int) -> URLRequest {
        var urlRequest = URLRequest(url: url)
        urlRequest.networkServiceType = .avStreaming
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.timeoutInterval = 60

        urlRequest.addValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.addValue("identity", forHTTPHeaderField: "Accept-Encoding")
        urlRequest.addValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        for (name, value) in headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        return urlRequest
    }
}
