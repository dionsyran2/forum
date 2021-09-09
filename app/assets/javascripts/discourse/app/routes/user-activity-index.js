import UserActivityStreamRoute from "discourse/routes/user-activity-stream";
import { iconHTML } from "discourse-common/lib/icon-library";
import getURL from "discourse-common/lib/get-url";
import I18n from "I18n";

export default UserActivityStreamRoute.extend({
  userActionType: null,
  emptyStateTitle: I18n.t("user_activity.no_activity_title"),

  emptyStateBody: I18n.t("user_activity.no_activity_body", {
    topUrl: getURL("/top"),
    categoriesUrl: getURL("/categories"),
    preferencesUrl: getURL("/my/preferences"),
    heartIcon: iconHTML("heart"),
  }).htmlSafe(),
});
