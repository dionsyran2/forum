import UserAction from "discourse/models/user-action";
import UserActivityStreamRoute from "discourse/routes/user-activity-stream";
import I18n from "I18n";

export default UserActivityStreamRoute.extend({
  userActionType: UserAction.TYPES["posts"],
  noContentHelpKey: "user_activity.no_replies",
  emptyStateTitle: I18n.t("user_activity.no_replies_title"),
  emptyStateBody: "",

  actions: {
    didTransition() {
      this.controllerFor("application").set("showFooter", true);
      return true;
    },
  },
});
