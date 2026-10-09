import Foundation
import Supabase

enum StockInService {
    /// 调用业务函数 stock_in。requestID 在点击确认时生成，重试时必须使用同一个，
    /// 数据库据此保证重复提交时库存只增加一次。
    static func stockIn(modelID: UUID, serialNos: [String], plannedQty: Int, requestID: UUID) async throws -> StockInResult {
        struct P: Encodable {
            let p_model_id: UUID
            let p_serial_nos: [String]
            let p_planned_qty: Int
            let p_request_id: UUID
        }
        return try await supabase.rpc("stock_in", params: P(
            p_model_id: modelID,
            p_serial_nos: serialNos,
            p_planned_qty: plannedQty,
            p_request_id: requestID
        )).execute().value
    }
}
