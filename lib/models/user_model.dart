import '../illust_model.dart' show Author;

/// Pixiv ユーザー最小モデル。
///
/// /v1/user/following / /v1/user/recommended / /v1/search/user 等で
/// 返却されるユーザー情報をそのまま保持する。
class User {
  final int userId;
  final String name;
  final String? account;
  final String? avatarUrl;
  final bool? isFollowed;

  const User({
    required this.userId,
    required this.name,
    this.account,
    this.avatarUrl,
    this.isFollowed,
  });

  factory User.fromJson(Map<String, dynamic> json) {
    final user = (json['user'] as Map<String, dynamic>? ?? json)
        .cast<String, dynamic>();
    final profileImageUrls =
        user['profile_image_urls'] as Map<String, dynamic>?;
    return User(
      userId: (user['id'] as num?)?.toInt() ?? 0,
      name: user['name']?.toString() ?? '',
      account: user['account']?.toString(),
      avatarUrl:
          profileImageUrls?['medium']?.toString() ??
          profileImageUrls?['large']?.toString(),
      isFollowed: user['is_followed'] as bool?,
    );
  }

  factory User.fromAuthor(Author author) {
    return User(
      userId: author.id,
      name: author.name,
      account: author.account,
      avatarUrl: author.avatar,
      isFollowed: null,
    );
  }

  Map<String, dynamic> toJson() => {
    'user_id': userId,
    'name': name,
    if (account != null) 'account': account,
    if (avatarUrl != null) 'avatar_url': avatarUrl,
    if (isFollowed != null) 'is_followed': isFollowed,
  };
}
