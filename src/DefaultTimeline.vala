/*  This file is part of corebird, a Gtk+ linux Twitter client.
 *  Copyright (C) 2013 Timm Bäder
 *
 *  corebird is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  corebird is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with corebird.  If not, see <http://www.gnu.org/licenses/>.
 */

/*
  XXX We are tracking min_id and max_id here AGAIN, even though we already
  do that in TweetModel. We are still adding raw Widgets in HomeTimeline
  because we need to scroll down, so the values in our TweetModel aren't always
  100% correct.
 */
public abstract class DefaultTimeline : ScrollWidget, IPage, ITimeline {
  protected bool initialized = false;
  public int id                          { get; set; }
  private int _unread_count = 0;
  public int unread_count {
    set {
      _unread_count = value;
      tool_button.show_badge = (_unread_count > 0);
      tool_button.queue_draw();
    }
    get {
      return this._unread_count;
    }
  }
  public unowned MainWindow main_window  { set; get; }
  protected TweetListBox tweet_list      { set; get; default=new TweetListBox ();}
  public unowned Account account         { get; set; }
  protected BadgeRadioToolButton tool_button;
  public int64 lowest_id                 { get; set; default = int64.MAX-2; }
  protected uint tweet_remove_timeout    { get; set; }
  protected int64 max_id                 { get; set; default = 0; }
  private DeltaUpdater _delta_updater;
  public DeltaUpdater delta_updater {
    get {
      return _delta_updater;
    }
    set {
      this._delta_updater = value;
      tweet_list.delta_updater = value;
    }
  }
  protected abstract string function     { get;      }
  protected bool loading = false;
  protected Gtk.Widget? last_focus_widget = null;


  public DefaultTimeline (int id) {
    this.id = id;
    this.scrolled_to_start.connect(handle_scrolled_to_start);
    this.scrolled_to_end.connect(() => {
      if (!loading) {
        load_older ();
      }
    });
    this.vadjustment.notify["value"].connect (() => {
      mark_seen_on_scroll (vadjustment.value);
    });


    tweet_list.set_sort_func(ITwitterItem.sort_func);
    this.add (tweet_list);

    tweet_list.row_activated.connect ((row) => {
      if (row is TweetListEntry) {
        var bundle = new Bundle ();
        bundle.put_int ("mode", TweetInfoPage.BY_INSTANCE);
        bundle.put_object ("tweet", ((TweetListEntry)row).tweet);
        main_window.main_widget.switch_page (Page.TWEET_INFO, bundle);
      }
      last_focus_widget = row;
    });
    tweet_list.retry_button_clicked.connect (() => {
      tweet_list.model.clear ();
      tweet_list.remove_progress_entry ();
      this.load_newest ();
    });

  }

  public virtual void on_join (int page_id, Bundle? args) {
    if (!initialized) {
      load_newest ();
      account.user_stream.resumed.connect (stream_resumed_cb);
      initialized = true;
    }

    if (Settings.auto_scroll_on_new_tweets ()) {
      this._unread_count = 0;
      mark_seen (-1);
    }

    if (last_focus_widget != null) {
      last_focus_widget.grab_focus ();
    }
  }


  public bool handles_double_open () {
    return true;
  }

  public void double_open () {
    if (!loading) {
      this.scroll_up_next (true, false, true);
      tweet_list.get_row_at_index (0).grab_focus ();
    }
  }

  public virtual void on_leave () {
    Gtk.Widget? focus_widget = main_window.get_focus ();
    if (focus_widget == null)
      return;

    GLib.List<weak Gtk.Widget> list_rows = tweet_list.get_children ();
    foreach (Gtk.Widget w in list_rows) {
      if (w == focus_widget) {
        last_focus_widget = w;
        break;
      }
    }

    if (tweet_list.action_entry != null && tweet_list.action_entry.shows_actions)
      tweet_list.action_entry.toggle_mode ();
  }

  public abstract void load_newest ();
  public abstract void load_older ();
  public abstract string? get_title ();

  public override void destroy () {
    if (tweet_remove_timeout > 0) {
      GLib.Source.remove (tweet_remove_timeout);
      tweet_remove_timeout = 0;
    }
  }

  public virtual void create_tool_button(Gtk.RadioButton? group){}

  public Gtk.RadioButton? get_tool_button() {
    return tool_button;
  }

  /**
   * Handle the case of the user scrolling to the start of the list,
   * i.e. remove all the items except a few ones after a timeout.
   */
  protected void handle_scrolled_to_start() { // {{{
    if (tweet_remove_timeout != 0)
      return;

    if (tweet_list.model.get_n_items () > ITimeline.REST) {
      tweet_remove_timeout = GLib.Timeout.add (500, () => {
        if (!scrolled_up) {
          tweet_remove_timeout = 0;
          return false;
        }

        tweet_list.model.remove_last_n_visible (tweet_list.model.get_n_items () - ITimeline.REST);
        lowest_id = tweet_list.model.lowest_id;
        return false;
      });
    } else if (tweet_remove_timeout != 0) {
      GLib.Source.remove (tweet_remove_timeout);
      tweet_remove_timeout = 0;
    }
  } // }}}

  public void delete_tweet (int64 tweet_id) { // {{{
    foreach (Gtk.Widget w in tweet_list.get_children ()) {
      if (w == null || !(w is TweetListEntry))
        continue;

      var tle = (TweetListEntry) w;
      if (tle.tweet.id == tweet_id) {
        if (!tle.tweet.seen) {
          tweet_list.remove (tle);
          this.unread_count --;
        }else
          tle.sensitive = false;
        return;
      } else if (tle.tweet.retweeted && tle.tweet.my_retweet == tweet_id) {
        tle.tweet.retweeted = false;
        return;
      }
    }
  } // }}}

  public void toggle_favorite (int64 id, bool mode) { // {{{
    var tweets = tweet_list.get_children ();

    foreach (var w in tweets) {
      if (!(w is TweetListEntry))
        continue;
      var t = ((TweetListEntry)w).tweet;
      if (t.id == id) {
        t.favorited = mode;
        break;
      }
    }
  } // }}}


  /**
   * So, we don't want to display a retweet in the following situations:
   *   1) If the original tweet was a tweet by the authenticated user
   *   2) In any case, if the user follows the author of the tweet
   *      (not the author of the retweet!), we already get the source
   *      tweet by other means, so don't display it again.
   *   3) It's a retweet from the authenticating user itself
   *   4) If the tweet was retweeted by a user that is on the list of
   *      users the authenticating user disabled RTs for.
   *   5) If the retweet is already in the timeline. There's no other
   *      way of checking the case where 2 indipendend users retweet
   *      the same tweet.
   */
  protected uint get_rt_flags (Tweet t) {
    uint flags = 0;

    /* First case */
    if (t.user_id == account.id)
      flags |= Tweet.HIDDEN_FORCE;

    /*  Second case */
    if (account.follows_id (t.user_id))
        flags |= Tweet.HIDDEN_RT_BY_FOLLOWEE;

    /* third case */
    if (t.rt_by_id == account.id)
      flags |= Tweet.HIDDEN_FORCE;

    /* Fourth case */
    foreach (int64 id in account.disabled_rts)
      if (id == t.rt_by_id) {
        flags |= Tweet.HIDDEN_RTS_DISABLED;
        break;
      }


    /* Fifth case */
    foreach (Gtk.Widget w in tweet_list.get_children ()) {
      if (w is TweetListEntry) {
        if (((TweetListEntry)w).tweet.rt_id == t.rt_id) {
          flags |= Tweet.HIDDEN_FORCE;
          break;
        }
      }
    }

    return flags;
  }

  protected void mark_seen (int64 id) {
    foreach (Gtk.Widget w in tweet_list.get_children ()) {
      if (w == null || !(w is TweetListEntry))
        continue;

      var tle = (TweetListEntry) w;
      if (tle.tweet.id == id || id == -1) {
        if (!tle.tweet.seen) {
          this.unread_count--;
        }
        tle.tweet.seen = true;
        break;
      }
    }
  }


  protected void scroll_up (Tweet t) {
    bool auto_scroll = Settings.auto_scroll_on_new_tweets ();
    if (this.scrolled_up && (t.user_id == account.id || auto_scroll)) {
      this.scroll_up_next (true, false,
                           main_window.cur_page_id != this.id);
    }

  }

  private void stream_resumed_cb () {
    // XXX If load_newest failed, the list still gets cleared...
    var call = account.proxy.new_call ();
    call.set_function (this.function);
    call.set_method ("GET");
    call.add_param ("count", "1");
    call.add_param ("since_id", (this.max_id + 1).to_string ());
    call.add_param ("trim_user", "true");
    call.add_param ("contributor_details", "false");
    call.add_param ("include_entities", "false");
    call.invoke_async.begin (null, (o, res) => {
      try {
        call.invoke_async.end (res);
      } catch (GLib.Error e) {
        tweet_list.model.clear ();
        tweet_list.remove_progress_entry ();
        load_newest ();
        warning (e.message);
        return;
      }

      var parser = new Json.Parser ();
      try {
        parser.load_from_data (call.get_payload ());
      } catch (GLib.Error e) {
        tweet_list.model.clear ();
        tweet_list.remove_progress_entry ();
        load_newest ();
        warning (e.message);
        return;
      }

      var root_arr = parser.get_root ().get_array ();
      if (root_arr.get_length () > 0) {
        tweet_list.model.clear ();
        tweet_list.remove_progress_entry ();
        unread_count = 0;
        load_newest ();
      }

    });
  }
}
