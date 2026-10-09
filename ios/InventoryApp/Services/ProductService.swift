import Foundation
import Supabase

/// 产品型号相关的读取与业务函数调用。
/// 读取直接查询表 / 视图（RLS 只读）；所有写操作都调用数据库业务函数。
enum ProductService {
    static func fetchModels() async throws -> [ProductModel] {
        try await supabase.from("v_model_stock")
            .select()
            .order("active", ascending: false)
            .order("name")
            .order("model")
            .execute()
            .value
    }

    static func fetchModel(id: UUID) async throws -> ProductModel? {
        let rows: [ProductModel] = try await supabase.from("v_model_stock")
            .select()
            .eq("id", value: id)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// 按产品条码识别型号；未建档返回 nil
    static func fetchModel(barcode: String) async throws -> ProductModel? {
        let rows: [ProductModel] = try await supabase.from("v_model_stock")
            .select()
            .eq("barcode", value: barcode)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    /// 查询某型号下的单台产品；不存在返回 nil
    static func fetchUnit(modelID: UUID, serialNo: String) async throws -> ProductUnit? {
        let rows: [ProductUnit] = try await supabase.from("units")
            .select("id,model_id,serial_no,status,last_in_at,last_out_at")
            .eq("model_id", value: modelID)
            .eq("serial_no", value: serialNo)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    static func fetchUnits(modelID: UUID, status: ProductUnit.Status? = nil) async throws -> [ProductUnit] {
        var query = supabase.from("units")
            .select("id,model_id,serial_no,status,last_in_at,last_out_at")
            .eq("model_id", value: modelID)
        if let status {
            query = query.eq("status", value: status.rawValue)
        }
        return try await query.order("serial_no").execute().value
    }

    // MARK: - 业务函数

    struct CreateParams: Encodable {
        var name: String
        var model: String
        var barcode: String
        var description: String?
        var photoPath: String?
        var serialNos: [String]
        var requestID: UUID

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(name, forKey: .p_name)
            try c.encode(model, forKey: .p_model)
            try c.encode(barcode, forKey: .p_barcode)
            try c.encode(description, forKey: .p_description)
            try c.encode(photoPath, forKey: .p_photo_path)
            try c.encode(serialNos.count, forKey: .p_initial_qty)
            try c.encode(serialNos, forKey: .p_serial_nos)
            try c.encode(requestID, forKey: .p_request_id)
        }

        enum Keys: String, CodingKey {
            case p_name, p_model, p_barcode, p_description, p_photo_path
            case p_initial_qty, p_serial_nos, p_request_id
        }
    }

    static func createModel(_ params: CreateParams) async throws -> CreateModelResult {
        try await supabase.rpc("create_model", params: params).execute().value
    }

    struct UpdateParams: Encodable {
        var id: UUID
        var name: String
        var model: String
        var barcode: String
        var description: String?
        var photoPath: String?
        var active: Bool

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(id, forKey: .p_model_id)
            try c.encode(name, forKey: .p_name)
            try c.encode(model, forKey: .p_model)
            try c.encode(barcode, forKey: .p_barcode)
            try c.encode(description, forKey: .p_description)
            try c.encode(photoPath, forKey: .p_photo_path)
            try c.encode(active, forKey: .p_active)
        }

        enum Keys: String, CodingKey {
            case p_model_id, p_name, p_model, p_barcode, p_description, p_photo_path, p_active
        }
    }

    static func updateModel(_ params: UpdateParams) async throws {
        try await supabase.rpc("update_model", params: params).execute()
    }

    /// 把未建档的条码绑定到已有型号（替换该型号原来的产品条码）
    static func bindBarcode(modelID: UUID, barcode: String) async throws {
        struct P: Encodable { let p_model_id: UUID; let p_barcode: String }
        try await supabase.rpc("bind_barcode", params: P(p_model_id: modelID, p_barcode: barcode)).execute()
    }

    static func setActive(modelID: UUID, active: Bool) async throws {
        struct P: Encodable { let p_model_id: UUID; let p_active: Bool }
        try await supabase.rpc("set_model_active", params: P(p_model_id: modelID, p_active: active)).execute()
    }

    /// 删除从未有出入库记录的型号，同时删除其照片
    static func deleteModel(_ model: ProductModel) async throws {
        struct P: Encodable { let p_model_id: UUID }
        try await supabase.rpc("delete_model", params: P(p_model_id: model.id)).execute()
        if let path = model.photoPath {
            await PhotoService.remove(path: path)
        }
    }
}
