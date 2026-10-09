import Foundation

/// 导航目标。用独立类型区分，同一个导航栈里可以同时打开经销商详情和订单详情。
struct DealerLink: Hashable {
    let id: UUID
}

struct OrderLink: Hashable {
    let id: UUID
}
