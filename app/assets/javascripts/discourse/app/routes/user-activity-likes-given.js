import UserAction from "discourse/models/user-action";
import UserActivityStreamRoute from "discourse/routes/user-activity-stream";
import { iconHTML } from "discourse-common/lib/icon-library";
import I18n from "I18n";

export default UserActivityStreamRoute.extend({
  userActionType: UserAction.TYPES["likes_given"],
  noContentHelpKey: "user_activity.no_likes_given",
  emptyStateTitle: I18n.t("user_activity.no_likes_title"),

  emptyStateBody: I18n.t("user_activity.no_likes_body", {
    heartIcon: iconHTML("heart"),
  }).htmlSafe(),

  actions: {
    didTransition() {
      this.controllerFor("application").set("showFooter", true);
      return true;
    },
  },
});
