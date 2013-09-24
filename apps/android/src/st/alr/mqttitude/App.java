
package st.alr.mqttitude;

import st.alr.mqttitude.support.Defaults;
import android.app.Application;

import com.bugsnag.android.Bugsnag;


public class App extends Application {
    @Override
    public void onCreate() {
        super.onCreate();
        Bugsnag.register(this, Defaults.BUGSNAG_API_KEY);
        Bugsnag.setNotifyReleaseStages("production", "testing");
    }
}
