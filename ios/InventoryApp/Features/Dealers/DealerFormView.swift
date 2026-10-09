import SwiftUI

/// 添加与编辑经销商（Issue #24）
///   新增：公司名称、联系人、电话、至少一个地址（可指定默认地址）
///   编辑：公司名称、联系人、电话、启用状态（地址在详情页管理）
struct DealerFormView: View {
    /// 表单中的一行地址。带固定 id，删除行时 ForEach 按 id 而不是下标识别，避免下标越界崩溃
    private struct AddressDraft: Identifiable {
        let id = UUID()
        var label = ""
        var address = ""
        var isDefault = false
    }

    /// nil 表示新增
    let dealer: Dealer?
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var network: NetworkMonitor

    @State private var companyName = ""
    @State private var contactName = ""
    @State private var phone = ""
    @State private var active = true
    @State private var addresses = [AddressDraft(isDefault: true)]
    @State private var saving = false
    @State private var error: String?
    @State private var requestID = UUID()
    /// 上次提交的内容；内容变化后换新的请求编号，否则服务器会直接返回上次的结果
    @State private var lastParams: DealerService.CreateParams?
    @State private var loaded = false

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var validationMessage: String? {
        if trimmed(companyName).isEmpty { return "请填写公司名称" }
        if trimmed(contactName).isEmpty { return "请填写联系人" }
        if trimmed(phone).isEmpty { return "请填写电话号码" }
        if dealer == nil {
            if addresses.isEmpty { return "请至少填写一个地址" }
            if addresses.contains(where: { trimmed($0.address).isEmpty }) { return "请填写详细地址" }
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    }
                }

                Section("基本资料") {
                    TextField("公司名称（必填）", text: $companyName)
                    TextField("联系人（必填）", text: $contactName)
                    TextField("电话号码（必填）", text: $phone)
                        .keyboardType(.phonePad)
                }

                if dealer != nil {
                    Section {
                        Toggle("启用", isOn: $active)
                    } footer: {
                        Text("停用后不能用于新建出库订单，历史订单仍可查询。")
                    }
                } else {
                    addressSection
                }
            }
            .navigationTitle(dealer == nil ? "添加经销商" : "编辑经销商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("保存", action: save)
                            .disabled(validationMessage != nil)
                            .requiresOnline()
                    }
                }
            }
            .interactiveDismissDisabled(saving)
            .onAppear(perform: load)
        }
    }

    private var addressSection: some View {
        Section {
            ForEach($addresses) { $draft in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("地址名称（选填，例如公司、仓库）", text: $draft.label)
                        Button {
                            for i in addresses.indices { addresses[i].isDefault = (addresses[i].id == draft.id) }
                        } label: {
                            Label("默认", systemImage: draft.isDefault ? "checkmark.circle.fill" : "circle")
                        }
                        .buttonStyle(.borderless)
                        if addresses.count > 1 {
                            Button(role: .destructive) {
                                let wasDefault = draft.isDefault
                                addresses.removeAll { $0.id == draft.id }
                                if wasDefault, !addresses.isEmpty { addresses[0].isDefault = true }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("删除地址")
                        }
                    }
                    TextField("详细地址（必填）", text: $draft.address, axis: .vertical)
                        .lineLimit(1...3)
                }
                .padding(.vertical, 4)
            }
            Button {
                addresses.append(AddressDraft())
            } label: {
                Label("添加地址", systemImage: "plus.circle")
            }
        } header: {
            Text("地址")
        } footer: {
            Text("一个经销商可以保存多个地址，最多一个默认地址。新建出库订单时自动选择默认地址。")
        }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let dealer {
            companyName = dealer.companyName
            contactName = dealer.contactName
            phone = dealer.phone
            active = dealer.active
        }
    }

    private func save() {
        guard validationMessage == nil, !saving, network.isOnline else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                if let dealer {
                    try await DealerService.updateDealer(
                        id: dealer.id, companyName: trimmed(companyName), contactName: trimmed(contactName),
                        phone: trimmed(phone), active: active)
                } else {
                    try await create()
                }
                onSaved()
                dismiss()
            } catch {
                self.error = AppError.message(error)
            }
        }
    }

    private func create() async throws {
        var params = DealerService.CreateParams(
            companyName: trimmed(companyName), contactName: trimmed(contactName), phone: trimmed(phone),
            addresses: addresses.map {
                .init(label: trimmed($0.label), address: trimmed($0.address), isDefault: $0.isDefault)
            },
            requestID: requestID)
        if let last = lastParams, last != params {
            requestID = UUID()
            params.requestID = requestID
        }
        lastParams = params
        do {
            _ = try await DealerService.createDealer(params)
        } catch {
            // 业务错误（例如公司名称重复）已整体回滚，修改后用新的请求编号重新提交；
            // 网络错误保留请求编号，重试不会重复创建
            if AppError.isBusiness(error) {
                requestID = UUID()
                lastParams = nil
            }
            throw error
        }
    }
}
