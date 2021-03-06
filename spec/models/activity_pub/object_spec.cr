require "../../../src/models/activity_pub/object"
require "../../../src/models/activity_pub/activity/announce"
require "../../../src/models/activity_pub/activity/like"

require "../../spec_helper/model"

class FooBarObject < ActivityPub::Object
end

Spectator.describe ActivityPub::Object do
  setup_spec

  describe "#source=" do
    subject { described_class.new(iri: "https://test.test/objects/#{random_string}") }
    let(source) { ActivityPub::Object::Source.new("foobar #foobar @foo@bar.com", "text/html") }

    it "assigns content" do
      expect{subject.assign(source: source).save}.to change{subject.content}
    end

    it "assigns media type" do
      expect{subject.assign(source: source).save}.to change{subject.media_type}
    end

    it "assigns attachments" do
      expect{subject.assign(source: source).save}.to change{subject.attachments}
    end

    it "assigns hashtags" do
      expect{subject.assign(source: source).save}.to change{subject.hashtags}
    end

    it "creates hashtags" do
      expect{subject.assign(source: source).save}.to change{Tag::Hashtag.count(subject_iri: subject.iri)}.by(1)
    end

    it "assigns mentions" do
      expect{subject.assign(source: source).save}.to change{subject.mentions}
    end

    it "creates mentions" do
      expect{subject.assign(source: source).save}.to change{Tag::Mention.count(subject_iri: subject.iri)}.by(1)
    end

    it "doesn't assign if the object isn't local" do
      expect{subject.assign(iri: "https://remote/object", source: source).save}.not_to change{subject.content}
    end

    context "addressing (to)" do
      before_each do
        ActivityPub::Actor.new(
          iri: "https://bar.com/foo",
          urls: ["https://bar.com/@foo"],
          username: "foo"
        ).save
      end

      it "replaces recipients if draft" do
        subject.assign(to: ["https://test.test/actor"], source: source).save
        expect(subject.to).to eq(["https://bar.com/foo"])
      end

      it "appends recipients if published" do
        subject.assign(to: ["https://test.test/actor"], source: source, published: Time.utc).save
        expect(subject.to).to eq(["https://test.test/actor", "https://bar.com/foo"])
      end
    end
  end

  context "when validating" do
    it "is valid" do
      expect(described_class.new(iri: "https://test.test/#{random_string}").valid?).to be_true
    end
  end

  let(json) do
    <<-JSON
      {
        "@context":[
          "https://www.w3.org/ns/activitystreams"
        ],
        "@id":"https://remote/foo_bar",
        "@type":"FooBarObject",
        "published":"2016-02-15T10:20:30Z",
        "attributedTo":{
          "id":"attributed to link"
        },
        "inReplyTo":"in reply to link",
        "replies":{
          "id":"replies link"
        },
        "to":"to link",
        "cc":["cc link"],
        "summary":"abc",
        "content":"abc",
        "mediaType":"xyz",
        "attachment":[
          {
            "url":"attachment link",
            "mediaType":"type"
          }
        ],
        "url":"url link"
      }
    JSON
  end

  describe ".from_json_ld" do
    it "instantiates the subclass" do
      object = described_class.from_json_ld(json)
      expect(object.class).to eq(FooBarObject)
    end

    it "creates a new instance" do
      object = described_class.from_json_ld(json).save
      expect(object.iri).to eq("https://remote/foo_bar")
      expect(object.published).to eq(Time.utc(2016, 2, 15, 10, 20, 30))
      expect(object.attributed_to_iri).to eq("attributed to link")
      expect(object.in_reply_to_iri).to eq("in reply to link")
      expect(object.replies).to eq("replies link")
      expect(object.to).to eq(["to link"])
      expect(object.cc).to eq(["cc link"])
      expect(object.summary).to eq("abc")
      expect(object.content).to eq("abc")
      expect(object.media_type).to eq("xyz")
      expect(object.attachments).to eq([ActivityPub::Object::Attachment.new("attachment link", "type")])
      expect(object.urls).to eq(["url link"])
    end

    context "when addressed to the public collection" do
      it "is visible" do
        json = self.json.gsub("to link", "https://www.w3.org/ns/activitystreams#Public")
        object = described_class.from_json_ld(json).save
        expect(object.visible).to be_true
      end
    end
  end

  describe "#from_json_ld" do
    it "updates an existing instance" do
      object = described_class.new.from_json_ld(json).save
      expect(object.iri).to eq("https://remote/foo_bar")
      expect(object.published).to eq(Time.utc(2016, 2, 15, 10, 20, 30))
      expect(object.attributed_to_iri).to eq("attributed to link")
      expect(object.in_reply_to_iri).to eq("in reply to link")
      expect(object.replies).to eq("replies link")
      expect(object.to).to eq(["to link"])
      expect(object.cc).to eq(["cc link"])
      expect(object.summary).to eq("abc")
      expect(object.content).to eq("abc")
      expect(object.media_type).to eq("xyz")
      expect(object.attachments).to eq([ActivityPub::Object::Attachment.new("attachment link", "type")])
      expect(object.urls).to eq(["url link"])
    end

    context "when addressed to the public collection" do
      it "is visible" do
        json = self.json.gsub("cc link", "https://www.w3.org/ns/activitystreams#Public")
        object = described_class.new.from_json_ld(json).save
        expect(object.visible).to be_true
      end
    end
  end

  describe "#to_json_ld" do
    it "renders an identical instance" do
      object = described_class.from_json_ld(json)
      expect(described_class.from_json_ld(object.to_json_ld)).to eq(object)
    end

    it "renders hashtags" do
      object = described_class.new(
        iri: "https://test.test/object",
        hashtags: [Tag::Hashtag.new(name: "foo", href: "https://test.test/tags/foo")]
      ).save
      expect(JSON.parse(object.to_json_ld).dig("tag").as_a).to contain_exactly({"type" => "Hashtag", "name" => "#foo", "href" => "https://test.test/tags/foo"})
    end

    it "renders mentions" do
      object = described_class.new(
        iri: "https://test.test/object",
        mentions: [Tag::Mention.new(name: "foo@test.test", href: "https://test.test/actors/foo")]
      ).save
      expect(JSON.parse(object.to_json_ld).dig("tag").as_a).to contain_exactly({"type" => "Mention", "name" => "@foo@test.test", "href" => "https://test.test/actors/foo"})
    end
  end

  describe ".federated_posts" do
    macro post(index)
      let!(post{{index}}) do
        ActivityPub::Object.new(
          iri: "https://test.test/objects/#{random_string}",
          published: Time.utc(2016, 2, 15, 10, 20, {{index}}),
          visible: {{index}}.odd?
        ).save
      end
    end

    post(1)
    post(2)
    post(3)
    post(4)
    post(5)

    it "instantiates the correct subclass" do
      expect(described_class.federated_posts(1, 2).first).to be_a(ActivityPub::Object)
    end

    it "filters out non-public posts" do
      expect(described_class.federated_posts(1, 2)).to eq([post5, post3])
    end

    it "filters out deleted posts" do
      post5.delete
      expect(described_class.federated_posts(1, 2)).to eq([post3, post1])
    end

    it "paginates the results" do
      expect(described_class.federated_posts(1, 2)).to eq([post5, post3])
      expect(described_class.federated_posts(2, 2)).to eq([post1])
      expect(described_class.federated_posts(2, 2).more?).not_to be_true
    end
  end

  describe "#with_statistics!" do
    let(object) do
      described_class.new(
        iri: "https://test.test/objects/#{random_string}"
      )
    end
    let(announce) do
      ActivityPub::Activity::Announce.new(
        iri: "https://test.test/announce",
        object: object
      )
    end
    let(like) do
      ActivityPub::Activity::Like.new(
        iri: "https://test.test/like",
        object: object
      )
    end

    it "updates announces count" do
      announce.save
      expect(object.with_statistics!.announces_count).to eq(1)
      expect(object.with_statistics!.likes_count).to eq(0)
    end

    it "updates likes count" do
      like.save
      expect(object.with_statistics!.announces_count).to eq(0)
      expect(object.with_statistics!.likes_count).to eq(1)
    end

    it "doesn't fail when the object hasn't been saved" do
      expect(object.with_statistics!.announces_count).to eq(0)
      expect(object.with_statistics!.likes_count).to eq(0)
    end
  end

  context "when threaded" do
    subject { described_class.new(iri: "https://test.test/objects/#{random_string}").save }

    macro reply_to!(object, reply)
      let!({{reply}}) do
        described_class.new(
          iri: "https://test.test/objects/#{random_string}",
          in_reply_to: {{object}}
        ).save
      end
    end

    # Nesting:
    # S           id=1
    #   1         id=2
    #     2       id=4
    #       3     id=5
    #   4         id=3
    #     5       id=6

    reply_to!(subject, object1)
    reply_to!(subject, object4)
    reply_to!(object1, object2)
    reply_to!(object2, object3)
    reply_to!(object4, object5)

    let(announce) do
      ActivityPub::Activity::Announce.new(
        iri: "https://test.test/announce",
        object: object2
      )
    end
    let(like) do
      ActivityPub::Activity::Like.new(
        iri: "https://test.test/like",
        object: object5
      )
    end

    describe "#with_replies_count!" do
      it "returns the count of replies" do
        expect(subject.with_replies_count!.replies_count).to eq(5)
        expect(object5.with_replies_count!.replies_count).to eq(0)
      end

      it "omits deleted replies but includes their children" do
        object4.delete
        expect(subject.with_replies_count!.replies_count).to eq(4)
      end

      it "omits destroyed replies and their children" do
        object4.destroy
        expect(subject.with_replies_count!.replies_count).to eq(3)
      end
    end

    describe "#thread" do
      it "returns all replies properly nested" do
        expect(subject.thread).to eq([subject, object1, object2, object3, object4, object5])
        expect(object1.thread).to eq([subject, object1, object2, object3, object4, object5])
        expect(object5.thread).to eq([subject, object1, object2, object3, object4, object5])
      end

      it "omits deleted replies but includes their children" do
        object4.delete
        expect(subject.thread).to eq([subject, object1, object2, object3, object5])
      end

      it "omits destroyed replies and their children" do
        object4.destroy
        expect(subject.thread).to eq([subject, object1, object2, object3])
      end

      it "returns the depths" do
        expect(object5.thread.map(&.depth)).to eq([0, 1, 2, 3, 1, 2])
      end

      it "includes count of announcements" do
        announce.save
        expect(object5.thread.map(&.announces_count)).to eq([0, 0, 1, 0, 0, 0])
      end

      it "includes count of likes" do
        like.save
        expect(object5.thread.map(&.likes_count)).to eq([0, 0, 0, 0, 0, 1])
      end
    end

    describe "#ancestors" do
      it "returns all ancestors" do
        expect(subject.ancestors).to eq([subject])
        expect(object3.ancestors).to eq([object3, object2, object1, subject])
        expect(object5.ancestors).to eq([object5, object4, subject])
      end

      it "omits deleted replies but includes their parents" do
        object1.delete
        expect(object3.ancestors).to eq([object3, object2, subject])
      end

      it "omits destroyed replies and their parents" do
        object1.destroy
        expect(object3.ancestors).to eq([object3, object2])
      end

      it "returns the depths" do
        expect(object5.ancestors.map(&.depth)).to eq([0, 1, 2])
      end
    end

    describe "#draft?" do
      subject do
        described_class.new(
          iri: "https://test.test/objects/#{random_string}"
        ).save
      end

      it "returns true if draft" do
        expect(subject.draft?).to be_true
      end

      it "returns false if not local" do
        expect(subject.assign(iri: "https://remote/object").draft?).to be_false
      end

      it "returns false if published" do
        expect(subject.assign(published: Time.utc).draft?).to be_false
      end
    end

    describe "#tags" do
      let(hashtag) { Tag::Hashtag.new(name: "foo", href: "https://test.test/tags/foo") }
      let(mention) { Tag::Mention.new(name: "foo@test.test", href: "https://test.test/actors/foo") }
      subject do
        described_class.new(
          iri: "https://test.test/object",
          hashtags: [hashtag],
          mentions: [mention]
        ).save
      end

      it "returns tags" do
        expect(subject.tags).to contain_exactly(hashtag, mention)
      end
    end
  end
end
