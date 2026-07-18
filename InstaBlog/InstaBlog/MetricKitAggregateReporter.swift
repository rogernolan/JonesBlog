import MetricKit
import Sentry

nonisolated final class MetricKitAggregateReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = MetricKitAggregateReporter()

    private override init() {
        super.init()
    }

    func start() {
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            let attachment = Attachment(
                data: payload.jsonRepresentation(),
                filename: "MXMetricPayload.json",
                contentType: "application/json"
            )

            SentrySDK.capture(message: "MetricKit aggregate metrics received") { scope in
                scope.setTag(value: "aggregate", key: "metrickit.payload_type")
                scope.setExtra(
                    value: payload.timeStampBegin.ISO8601Format(),
                    key: "metrickit.period_start"
                )
                scope.setExtra(
                    value: payload.timeStampEnd.ISO8601Format(),
                    key: "metrickit.period_end"
                )
                scope.addAttachment(attachment)
            }
        }
    }
}
